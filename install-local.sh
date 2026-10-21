#!/usr/bin/env bash
# install-local.sh
#
# Локальный установщик для тестирования mozaroc/3x-ui-pro + Hysteria2
# без заливки на GitHub. Берёт add-hysteria2.sh и clash.yaml из той же папки.
#
# Usage:
#   sudo bash install-local.sh <panel-domain> <reality-domain>
#
# Example:
#   sudo bash install-local.sh kone.vkvideo.download nokia.vkvideo.download

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADD_HYSTERIA="$SCRIPT_DIR/add-hysteria2.sh"
CLASH_TEMPLATE="$SCRIPT_DIR/assets/clash/clash.yaml"
CREDS_FILE="/root/3x-ui-pro-credentials.txt"
UPSTREAM_LOG="/var/log/3x-ui-pro-install.log"

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

[[ $# -eq 2 ]] || die "Usage: bash install-local.sh <panel-domain> <reality-domain>"
PANEL_DOMAIN_IN="$1"
REALITY_DOMAIN_IN="$2"

[[ -f "$ADD_HYSTERIA" ]] || die "add-hysteria2.sh not found in $SCRIPT_DIR"
[[ -f "$CLASH_TEMPLATE" ]] || die "clash.yaml not found in $SCRIPT_DIR"

# ─── 1. Base dependencies ────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq curl wget jq openssl sqlite3 ufw netcat-openbsd qrencode >/dev/null 2>&1 || true

# ─── 2. Run upstream mozaroc/3x-ui-pro installer and capture output ──────────
green "Running mozaroc/3x-ui-pro installer..."
UPSTREAM="https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-latest.sh"
curl -fsSL "$UPSTREAM" -o /tmp/x-ui-latest.sh || die "Cannot download upstream installer"

bash /tmp/x-ui-latest.sh -subdomain "$PANEL_DOMAIN_IN" -reality_domain "$REALITY_DOMAIN_IN" 2>&1 | tee "$UPSTREAM_LOG"

# Extract credentials from the installer output
PANEL_URL=$(grep -oP 'X-UI Secure Panel:\s*\Khttps?://[^ ]+' "$UPSTREAM_LOG" | tail -1)
PANEL_USER=$(grep -oP 'Username:\s*\K\S+' "$UPSTREAM_LOG" | tail -1)
PANEL_PASS=$(grep -oP 'Password:\s*\K\S+' "$UPSTREAM_LOG" | tail -1)

[[ -n "$PANEL_URL" && -n "$PANEL_USER" && -n "$PANEL_PASS" ]] || die "Cannot extract panel credentials from installer output"

{
    echo "=== 3x-ui-pro panel credentials ==="
    echo "URL     : $PANEL_URL"
    echo "Username: $PANEL_USER"
    echo "Password: $PANEL_PASS"
} > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

green "Panel credentials saved"

# ─── 3. Read panel settings for Clash template ───────────────────────────────
XUI_DB="/etc/x-ui/x-ui.db"
[[ -f "$XUI_DB" ]] || die "3x-ui database not found after upstream install"

PANEL_DOMAIN=$(basename "$(dirname "$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webCertFile';")")")
[[ -n "$PANEL_DOMAIN" ]] || die "Cannot derive panel domain from certificate"

# ─── 4. Add Hysteria2 and unify subscription ─────────────────────────────────
green "Adding Hysteria2 and unifying subscription..."
bash "$ADD_HYSTERIA"

# ─── 5. Replace Clash template with Hysteria2-aware version ──────────────────
SUBPAGE_DIR="/var/www/subpage"
mkdir -p "$SUBPAGE_DIR"
cp "$CLASH_TEMPLATE" "${SUBPAGE_DIR}/clash.yaml.tpl"
sed -i "s|\${DOMAIN}|${PANEL_DOMAIN}|g" "${SUBPAGE_DIR}/clash.yaml.tpl"
SUB_PATH=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPath';")
SUB_PATH="${SUB_PATH#/}"
SUB_PATH="${SUB_PATH%/}"
sed -i "s|\${SUB_PATH}|${SUB_PATH}|g" "${SUBPAGE_DIR}/clash.yaml.tpl"
chown -R www-data:www-data "$SUBPAGE_DIR" 2>/dev/null || true
chmod 644 "${SUBPAGE_DIR}/clash.yaml.tpl"

green ""
green "============================================================"
green "  mozaroc/3x-ui-pro + Hysteria2 installed"
green "============================================================"
echo ""
echo "Panel URL : $PANEL_URL"
echo "Username  : $PANEL_USER"
echo "Password  : $PANEL_PASS"
echo ""
if [[ -f /root/hysteria2-credentials.txt ]]; then
    cat /root/hysteria2-credentials.txt
fi
echo ""
green "Credentials saved to:"
green "  $CREDS_FILE"
green "  /root/hysteria2-credentials.txt"
