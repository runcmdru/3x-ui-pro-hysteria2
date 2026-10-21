#!/usr/bin/env bash
# add-hysteria2.sh
#
# Post-install hook for mozaroc/3x-ui-pro.
# Creates a Hysteria2 inbound on UDP/443, then creates one client and attaches
# it to all other inbounds so a single subscription (subId) includes every protocol.
#
# Usage (root):
#   bash add-hysteria2.sh

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq >/dev/null; }
command -v sqlite3 >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq sqlite3 >/dev/null; }

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

XUI_DB="/etc/x-ui/x-ui.db"
[[ -f "$XUI_DB" ]] || die "3x-ui database not found at $XUI_DB"

XUI_BIN="/usr/local/x-ui/x-ui"
[[ -x "$XUI_BIN" ]] || die "x-ui binary not found at $XUI_BIN"

# ─── Read panel settings from DB ─────────────────────────────────────────────
PANEL_PORT=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';")
PANEL_PATH=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webBasePath';")
WEB_CERT=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webCertFile';")
WEB_KEY=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webKeyFile';")
SUB_PATH=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPath';")

[[ -n "$PANEL_PORT" && -n "$PANEL_PATH" ]] || die "Cannot read panel settings from DB"
[[ -s "$WEB_CERT" && -s "$WEB_KEY" ]] || die "Panel certificates not found"

DOMAIN=$(basename "$(dirname "$WEB_CERT")")
[[ -n "$DOMAIN" ]] || die "Cannot derive domain from $WEB_CERT"

PANEL_PATH_TRIMMED="${PANEL_PATH#/}"
PANEL_PATH_TRIMMED="${PANEL_PATH_TRIMMED%/}"
API_BASE="https://127.0.0.1:${PANEL_PORT}/${PANEL_PATH_TRIMMED}/panel/api"

green "Domain   : $DOMAIN"
green "Panel API: $API_BASE"

# ─── API token via CLI ───────────────────────────────────────────────────────
API_TOKEN=$("$XUI_BIN" setting -getApiToken 2>/dev/null | sed -n 's/^apiToken: *//p' | tail -1 | tr -d '[:space:]')
[[ -n "$API_TOKEN" ]] || die "Cannot get API token from x-ui CLI"

green "API token obtained"

# ─── Check if Hysteria2 inbound already exists ───────────────────────────────
if sqlite3 "$XUI_DB" "SELECT 1 FROM inbounds WHERE protocol='hysteria' LIMIT 1;" 2>/dev/null | grep -q 1; then
    yellow "Hysteria2 inbound already exists."
    sqlite3 "$XUI_DB" "SELECT remark, port, listen FROM inbounds WHERE protocol='hysteria';"
    read -rp "Create another one? [y/N] " REPLY
    [[ "${REPLY:-}" =~ ^[yY]$ ]] || { echo "Cancelled."; exit 0; }
fi

# ─── Hysteria2 params ────────────────────────────────────────────────────────
HY_AUTH=$(openssl rand -hex 16)
HY_OBFS=$(openssl rand -hex 16)
HY_EMAIL="default"
HY_SUBID=$(openssl rand -hex 8)
HY_REMARK="Hysteria2 UDP/443"

HY_SETTINGS=$(jq -nc \
    --arg auth "$HY_AUTH" \
    --arg email "$HY_EMAIL" \
    --arg sub "$HY_SUBID" \
    '{
        version: 2,
        clients: [{
            auth: $auth, email: $email, limitIp: 0, totalGB: 0, expiryTime: 0,
            enable: true, tgId: "", subId: $sub, comment: "default", reset: 0
        }]
    }')

HY_STREAM=$(jq -nc \
    --arg sni "$DOMAIN" \
    --arg cert "$WEB_CERT" \
    --arg key "$WEB_KEY" \
    --arg obfs "$HY_OBFS" \
    '{
        network: "hysteria",
        security: "tls",
        externalProxy: [],
        finalmask: { udp: [{ type: "salamander", settings: { password: $obfs } }] },
        tlsSettings: {
            serverName: $sni,
            minVersion: "1.2", maxVersion: "1.3",
            cipherSuites: "", rejectUnknownSni: false,
            disableSystemRoot: false, enableSessionResumption: false,
            certificates: [{
                certificateFile: $cert, keyFile: $key,
                oneTimeLoading: false, usage: "encipherment", buildChain: false, useFile: true
            }],
            alpn: ["h3"],
            echServerKeys: "", echForceQuery: "none",
            settings: { fingerprint: "", echConfigList: "" }
        },
        hysteriaSettings: { version: 2, auth: "", udpIdleTimeout: 60 }
    }')

SNIFFING='{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

# ─── Create Hysteria2 inbound ────────────────────────────────────────────────
RESP=$(curl -ks --max-time 20 \
    -H "Authorization: Bearer $API_TOKEN" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "remark=$HY_REMARK" \
    --data-urlencode "enable=true" \
    --data-urlencode "listen=" \
    --data-urlencode "port=443" \
    --data-urlencode "protocol=hysteria" \
    --data-urlencode "expiryTime=0" \
    --data-urlencode "settings=$HY_SETTINGS" \
    --data-urlencode "streamSettings=$HY_STREAM" \
    --data-urlencode "sniffing=$SNIFFING" \
    "${API_BASE}/inbounds/add" 2>/dev/null) || die "Failed to POST Hysteria2 inbound"

if ! echo "$RESP" | jq -e '.success == true' >/dev/null 2>&1; then
    MSG=$(echo "$RESP" | jq -r '.msg // .' 2>/dev/null | head -c 500)
    die "Hysteria2 inbound creation failed: ${MSG:-$RESP}"
fi

HY_ID=$(echo "$RESP" | jq -r '.obj.id')
[[ -n "$HY_ID" && "$HY_ID" != "null" ]] || die "No inbound id returned"
green "Hysteria2 inbound created (id=$HY_ID)"

# ─── Attach one client to all other inbounds with the same subId ─────────────
OTHER_INBOUND_IDS=$(sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE enable=1 AND id != ${HY_ID} ORDER BY id;")
INBOUND_IDS_JSON=$(echo "$OTHER_INBOUND_IDS" | jq -R . | jq -s -c '. | map(tonumber)')

CLIENT_JSON=$(jq -nc \
    --arg email "$HY_EMAIL" \
    --arg sub "$HY_SUBID" \
    '{
        email: $email, subId: $sub, totalGB: 0, expiryTime: 0,
        limitIp: 0, enable: true, tgId: 0, comment: "default", reset: 0
    }')

RESP=$(curl -ks --max-time 20 \
    -H "Authorization: Bearer $API_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --argjson c "$CLIENT_JSON" --argjson ids "$INBOUND_IDS_JSON" '{client: $c, inboundIds: $ids}')" \
    "${API_BASE}/clients/add" 2>/dev/null) || die "Failed to POST client"

if ! echo "$RESP" | jq -e '.success == true' >/dev/null 2>&1; then
    MSG=$(echo "$RESP" | jq -r '.msg // .' 2>/dev/null | head -c 500)
    die "Client creation failed: ${MSG:-$RESP}"
fi

green "Client '$HY_EMAIL' attached to $(echo "$INBOUND_IDS_JSON" | jq 'length') inbounds"

# ─── Ensure UDP/443 is open in UFW ───────────────────────────────────────────
if command -v ufw >/dev/null 2>&1; then
    if ! ufw status | grep -qE "443/udp"; then
        ufw allow 443/udp >/dev/null 2>&1 || true
        green "UFW: allowed 443/udp"
    else
        yellow "UFW: 443/udp already allowed"
    fi
fi

# ─── Restart x-ui to apply the new config ────────────────────────────────────
systemctl restart x-ui >/dev/null 2>&1 || x-ui restart >/dev/null 2>&1 || true
sleep 2

# ─── Verify UDP/443 listener ─────────────────────────────────────────────────
if command -v ss >/dev/null 2>&1 && ss -ulnp 'sport = :443' 2>/dev/null | grep -q ':443'; then
    green "xray is listening on UDP/443"
else
    yellow "Could not verify UDP/443 listener; check: systemctl status x-ui"
fi

# ─── Build subscription URL and Hysteria2 link ───────────────────────────────
SUB_URL="https://${DOMAIN}${SUB_PATH}${HY_SUBID}"
HY_LINK="hysteria2://${HY_AUTH}@${DOMAIN}:443/?sni=${DOMAIN}&alpn=h3&obfs=salamander&obfs-password=${HY_OBFS}#$(printf '%s' "$HY_REMARK" | jq -sRr @uri)"

SUMMARY="/root/hysteria2-credentials.txt"
{
    echo "=== Hysteria2 + unified subscription (mozaroc/3x-ui-pro) ==="
    echo "Created: $(date -Iseconds)"
    echo "Domain: $DOMAIN"
    echo "Port: 443 UDP"
    echo "SNI: $DOMAIN"
    echo "ALPN: h3"
    echo "Obfs: salamander"
    echo "Obfs password: $HY_OBFS"
    echo "Auth: $HY_AUTH"
    echo "Email: $HY_EMAIL"
    echo "SubId: $HY_SUBID"
    echo ""
    echo "Subscription URL (all protocols):"
    echo "$SUB_URL"
    echo ""
    echo "Hysteria2 share link:"
    echo "$HY_LINK"
} > "$SUMMARY"
chmod 600 "$SUMMARY"

green ""
green "=== Done ==="
echo "Subscription (all protocols): $SUB_URL"
echo "Hysteria2 link:               $HY_LINK"
echo "Saved to:                     $SUMMARY"
