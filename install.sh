#!/usr/bin/env bash
# install.sh — mozaroc/3x-ui-pro + Hysteria2 (UDP/443) + Quad9 DoH + опциональный Cloudflare WARP
#
# Использование (root):
#   bash install.sh <panel-domain> <reality-domain> [--warp | --no-warp]
#
# Без флага скрипт спросит, ставить ли WARP. При включённом WARP весь трафик клиентов
# идёт через него. Если WARP недоступен, Xray переключается на прямой выход
# (balancer + observatory), без перезапуска.
#
# Переменные окружения:
#   REPO_RAW          базовый URL папки 3x-ui-pro-hysteria2 на GitHub (нужен при запуске через curl)
#   SKIP_DNS_CHECK=1  пропустить проверку A-записей доменов

set -Eeuo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/3x-ui-pro-hysteria2}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)

XUI_DB="/etc/x-ui/x-ui.db"
XUI_BIN="/usr/local/x-ui/x-ui"
UPSTREAM_URL="https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-latest.sh"
UPSTREAM_LOG="/var/log/3x-ui-pro-install.log"
PANEL_CREDS_FILE="/root/3x-ui-pro-credentials.txt"
HY_CREDS_FILE="/root/hysteria2-credentials.txt"
WARP_ENDPOINT="162.159.192.1:2408"

WARP_MODE="ask"
PANEL_DOMAIN_IN=""
REALITY_DOMAIN_IN=""
PANEL_URL=""
PANEL_USER=""
PANEL_PASS=""
PANEL_PORT=""
PANEL_PATH=""
SUB_PATH_T=""
DOMAIN=""
WEB_CERT=""
WEB_KEY=""
API_TOKEN=""
API_BASE=""
HY_AUTH=""
HY_OBFS=""
HY_SUBID=""
HY_LINK=""
SUB_URL=""
WARP_IP=""

red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускать от root"

ARGS=()
for arg in "$@"; do
  case "$arg" in
    --warp)    WARP_MODE="yes" ;;
    --no-warp) WARP_MODE="no" ;;
    -*)        die "Неизвестный флаг: $arg" ;;
    *)         ARGS+=("$arg") ;;
  esac
done
[[ ${#ARGS[@]} -eq 2 ]] || die "Usage: bash install.sh <panel-domain> <reality-domain> [--warp|--no-warp]"
PANEL_DOMAIN_IN="${ARGS[0]}"
REALITY_DOMAIN_IN="${ARGS[1]}"

preflight() {
  step "Предварительные проверки"

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) ;;
      *) yellow "ОС ${PRETTY_NAME:-неизвестна} не проверялась, продолжаю" ;;
    esac
  fi

  apt-get update -qq
  apt-get install -y -qq curl jq openssl sqlite3 dnsutils ufw qrencode >/dev/null \
    || die "Не удалось установить базовые пакеты"

  if [[ "${SKIP_DNS_CHECK:-0}" != "1" ]]; then
    local server_ip d resolved
    server_ip=$(curl -4 -fsS --max-time 10 https://ipinfo.io/ip || true)
    [[ -n "$server_ip" ]] || die "Не удалось определить внешний IPv4 сервера"
    for d in "$PANEL_DOMAIN_IN" "$REALITY_DOMAIN_IN"; do
      resolved=$(dig +short A "$d" | grep -E '^[0-9.]+$' | head -1 || true)
      if [[ "$resolved" != "$server_ip" ]]; then
        die "A-запись $d указывает на '${resolved:-ничего}', а IP сервера $server_ip. Исправь DNS или запусти с SKIP_DNS_CHECK=1"
      fi
    done
    green "DNS: оба домена указывают на $server_ip"
  fi

  local all_disabled
  all_disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)
  if [[ "$all_disabled" != "1" ]] || ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    die "IPv6 на сервере не отключён. Запусти vps-setup/setup-vps.sh, перезагрузи сервер и повтори установку"
  fi
  green "IPv6 отключён"
}

ask_warp() {
  if [[ "$WARP_MODE" == "ask" ]]; then
    if [[ -r /dev/tty ]]; then
      local answer=""
      read -rp "Ставим Cloudflare WARP (весь трафик клиентов через WARP)? [y/N] " answer < /dev/tty || true
      if [[ "$answer" =~ ^[yYдД]$ ]]; then WARP_MODE="yes"; else WARP_MODE="no"; fi
    else
      WARP_MODE="no"
    fi
  fi

  if [[ "$WARP_MODE" == "yes" ]]; then
    green "WARP: будет установлен"
  else
    green "WARP: не устанавливается, трафик идёт напрямую"
  fi
}

install_upstream() {
  if [[ -f "$XUI_DB" ]]; then
    yellow "3x-ui уже установлен, пропускаю установку mozaroc/3x-ui-pro"
    return
  fi

  step "Установка mozaroc/3x-ui-pro"
  curl -fsSL "$UPSTREAM_URL" -o /tmp/x-ui-latest.sh || die "Не удалось скачать установщик mozaroc"
  bash /tmp/x-ui-latest.sh -subdomain "$PANEL_DOMAIN_IN" -reality_domain "$REALITY_DOMAIN_IN" 2>&1 \
    | tee "$UPSTREAM_LOG" || die "Установщик mozaroc завершился с ошибкой, см. $UPSTREAM_LOG"

  local url user pass
  url=$(grep -oP 'X-UI Secure Panel:\s*\Khttps?://[^ ]+' "$UPSTREAM_LOG" | tail -1 || true)
  user=$(grep -oP 'Username:\s*\K\S+' "$UPSTREAM_LOG" | tail -1 || true)
  pass=$(grep -oP 'Password:\s*\K\S+' "$UPSTREAM_LOG" | tail -1 || true)
  [[ -n "$url" && -n "$user" && -n "$pass" ]] || die "Не удалось извлечь данные панели из вывода установщика"

  (
    umask 077
    {
      echo "=== 3x-ui-pro panel credentials ==="
      echo "URL     : $url"
      echo "Username: $user"
      echo "Password: $pass"
    } > "$PANEL_CREDS_FILE"
  )
  green "Доступ к панели сохранён в $PANEL_CREDS_FILE"
}

load_panel_creds() {
  if [[ ! -f "$PANEL_CREDS_FILE" ]]; then
    yellow "Нет файла $PANEL_CREDS_FILE, логин и пароль панели не будут выведены"
    return 0
  fi
  PANEL_URL=$(grep -oP '^URL\s*:\s*\K\S+' "$PANEL_CREDS_FILE" || true)
  PANEL_USER=$(grep -oP '^Username:\s*\K\S+' "$PANEL_CREDS_FILE" || true)
  PANEL_PASS=$(grep -oP '^Password:\s*\K\S+' "$PANEL_CREDS_FILE" || true)
}

read_xui_settings() {
  [[ -f "$XUI_DB" ]] || die "База 3x-ui не найдена: $XUI_DB"
  [[ -x "$XUI_BIN" ]] || die "Не найден бинарник x-ui: $XUI_BIN"

  local sub_path
  PANEL_PORT=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';")
  PANEL_PATH=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webBasePath';")
  WEB_CERT=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webCertFile';")
  WEB_KEY=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webKeyFile';")
  sub_path=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPath';")

  [[ -n "$PANEL_PORT" && -n "$PANEL_PATH" ]] || die "Не удалось прочитать настройки панели"
  [[ -s "$WEB_CERT" && -s "$WEB_KEY" ]] || die "Не найдены сертификаты панели: $WEB_CERT"

  DOMAIN=$(basename "$(dirname "$WEB_CERT")")
  PANEL_PATH="${PANEL_PATH#/}"
  PANEL_PATH="${PANEL_PATH%/}"
  SUB_PATH_T="${sub_path#/}"
  SUB_PATH_T="${SUB_PATH_T%/}"
  API_BASE="https://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}/panel/api"

  API_TOKEN=$("$XUI_BIN" setting -getApiToken 2>/dev/null | sed -n 's/^apiToken: *//p' | tail -1 | tr -d '[:space:]')
  [[ -n "$API_TOKEN" ]] || die "Не удалось получить API-токен панели"

  green "Домен: $DOMAIN, панель: https://${DOMAIN}/${PANEL_PATH}/"
}

install_warp() {
  step "Cloudflare WARP (wgcf + WireGuard)"
  apt-get install -y -qq wireguard-tools >/dev/null || die "Не удалось установить wireguard-tools"

  if [[ ! -x /usr/local/bin/wgcf ]]; then
    local ver
    ver=$(curl -sS --max-time 15 https://api.github.com/repos/ViRb3/wgcf/releases/latest | jq -r '.tag_name' 2>/dev/null | sed 's/^v//' || true)
    [[ -n "$ver" && "$ver" != "null" ]] || ver="2.3.1"
    curl -fsSL --max-time 60 "https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_amd64" \
      -o /usr/local/bin/wgcf || die "Не удалось скачать wgcf ${ver}"
    chmod +x /usr/local/bin/wgcf
  fi

  cd /root
  if [[ ! -f /root/wgcf-account.toml ]]; then
    wgcf register --accept-tos || die "Регистрация WARP не удалась"
  fi
  wgcf generate || die "wgcf generate не удался"

  local priv pub addr
  priv=$(grep '^PrivateKey' /root/wgcf-profile.conf | sed -E 's/^PrivateKey *= *//')
  pub=$(grep '^PublicKey' /root/wgcf-profile.conf | sed -E 's/^PublicKey *= *//')
  addr=$(grep '^Address' /root/wgcf-profile.conf | sed -E 's/^Address *= *([0-9.]+).*/\1/')
  [[ -n "$priv" && -n "$pub" && -n "$addr" ]] || die "Не удалось разобрать /root/wgcf-profile.conf"

  (
    umask 077
    cat > /etc/wireguard/wgcf.conf <<EOF
[Interface]
Table = off
PrivateKey = ${priv}
Address = ${addr}/32
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0
Endpoint = ${WARP_ENDPOINT}
PersistentKeepalive = 25
EOF
  )

  mkdir -p /etc/warp
  cat > /etc/warp/warp-route.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TABLE=51820
for _ in $(seq 1 60); do
    ip link show wgcf >/dev/null 2>&1 && break
    sleep 1
done
ip link show wgcf >/dev/null 2>&1 || { logger -t warp-route "интерфейс wgcf не найден"; exit 1; }
ip route replace default dev wgcf table "$TABLE"
while ip rule del fwmark 51820 lookup "$TABLE" 2>/dev/null; do :; done
ip rule add fwmark 51820 lookup "$TABLE"
EOF
  chmod +x /etc/warp/warp-route.sh

  cat > /etc/warp/warp-healthcheck.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
HS=$(wg show wgcf latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
NOW=$(date +%s)
if [[ -n "$HS" && "$HS" -gt 0 && $((NOW - HS)) -lt 180 ]]; then
    exit 0
fi
logger -t warp-healthcheck "нет handshake дольше 180 с, перезапуск wgcf"
systemctl restart wg-quick@wgcf.service
EOF
  chmod +x /etc/warp/warp-healthcheck.sh

  cat > /etc/systemd/system/warp-route.service <<'EOF'
[Unit]
Description=WARP policy routing
After=wg-quick@wgcf.service
Wants=wg-quick@wgcf.service
PartOf=wg-quick@wgcf.service

[Service]
Type=oneshot
ExecStart=/etc/warp/warp-route.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/warp-healthcheck.service <<'EOF'
[Unit]
Description=WARP healthcheck
After=wg-quick@wgcf.service warp-route.service
Wants=wg-quick@wgcf.service warp-route.service

[Service]
Type=oneshot
ExecStart=/etc/warp/warp-healthcheck.sh
EOF

  cat > /etc/systemd/system/warp-healthcheck.timer <<'EOF'
[Unit]
Description=Проверка WARP каждую минуту

[Timer]
OnBootSec=3min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

  mkdir -p /etc/systemd/system/x-ui.service.d
  cat > /etc/systemd/system/x-ui.service.d/warp.conf <<'EOF'
[Unit]
After=wg-quick@wgcf.service warp-route.service
Wants=wg-quick@wgcf.service warp-route.service
EOF

  systemctl daemon-reload
  systemctl enable wg-quick@wgcf warp-route.service >/dev/null 2>&1
  systemctl restart wg-quick@wgcf
  systemctl restart warp-route.service
  systemctl enable --now warp-healthcheck.timer >/dev/null 2>&1

  for _ in $(seq 1 30); do
    if wg show wgcf latest-handshakes 2>/dev/null | awk '$2>0{f=1} END{exit !f}'; then
      break
    fi
    sleep 1
  done
  if wg show wgcf latest-handshakes 2>/dev/null | awk '$2>0{f=1} END{exit !f}'; then
    green "WARP: handshake выполнен"
  else
    yellow "WARP: handshake пока не выполнен, healthcheck будет повторять попытки"
  fi
}

disable_warp() {
  if [[ -f /etc/wireguard/wgcf.conf ]] || systemctl is-enabled --quiet wg-quick@wgcf 2>/dev/null; then
    yellow "WARP не выбран, отключаю ранее установленный wgcf"
    systemctl disable --now warp-healthcheck.timer >/dev/null 2>&1 || true
    systemctl disable --now warp-route.service >/dev/null 2>&1 || true
    systemctl disable --now wg-quick@wgcf >/dev/null 2>&1 || true
    while ip rule del fwmark 51820 lookup 51820 2>/dev/null; do :; done
    ip route flush table 51820 2>/dev/null || true
    rm -f /etc/systemd/system/x-ui.service.d/warp.conf
    systemctl daemon-reload
  fi
}

api_xray_get() {
  curl -ks --max-time 20 -H "Authorization: Bearer $API_TOKEN" -X POST "${API_BASE}/xray/" \
    | jq -r '.obj' | jq -r '.xraySetting'
}

configure_xray() {
  step "Xray: DNS Quad9 DoH и маршрутизация"

  local current modified resp
  current=$(api_xray_get) || die "Не удалось запросить настройки Xray у панели"
  [[ -n "$current" && "$current" != "null" ]] || die "Не удалось прочитать настройки Xray"

  local dns_json direct_json warp_json
  dns_json='{"servers":["https://dns.quad9.net/dns-query","localhost"],"queryStrategy":"UseIPv4","tag":"dns-quad9","hosts":{"dns.quad9.net":"9.9.9.9"}}'
  direct_json='{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4"},"tag":"direct"}'
  warp_json='{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4"},"tag":"WARP","streamSettings":{"sockopt":{"interface":"wgcf","mark":51820}}}'

  if [[ "$WARP_MODE" == "yes" ]]; then
    modified=$(jq --argjson dns "$dns_json" --argjson direct "$direct_json" --argjson warp "$warp_json" '
      .dns = $dns
      | .outbounds = ((.outbounds // []) | map(select(.tag != "WARP")))
      | .outbounds += (if any(.outbounds[]; .tag == "direct") then [] else [$direct] end)
      | .outbounds += [$warp]
      | .observatory = {subjectSelector: ["WARP"], probeUrl: "https://www.gstatic.com/generate_204", probeInterval: "30s", enableConcurrency: false}
      | .routing.balancers = (((.routing.balancers // []) | map(select(.tag != "warp-or-direct"))) + [{tag: "warp-or-direct", selector: ["WARP"], fallbackTag: "direct"}])
      | .routing.rules = (((.routing.rules // []) | map(select((.outboundTag // "") != "WARP" and (.balancerTag // "") != "warp-or-direct"))) + [{type: "field", network: "tcp,udp", balancerTag: "warp-or-direct"}])
    ' <<<"$current") || die "Не удалось собрать настройки Xray (WARP)"
  else
    modified=$(jq --argjson dns "$dns_json" --argjson direct "$direct_json" '
      .dns = $dns
      | .outbounds = ((.outbounds // []) | map(select(.tag != "WARP")))
      | .outbounds += (if any(.outbounds[]; .tag == "direct") then [] else [$direct] end)
      | del(.observatory)
      | .routing.balancers = ((.routing.balancers // []) | map(select(.tag != "warp-or-direct")))
      | .routing.rules = (((.routing.rules // []) | map(select((.outboundTag // "") != "WARP" and (.balancerTag // "") != "warp-or-direct"))) + [{type: "field", network: "tcp,udp", outboundTag: "direct"}])
    ' <<<"$current") || die "Не удалось собрать настройки Xray"
  fi

  resp=$(curl -ks --max-time 30 \
    -H "Authorization: Bearer $API_TOKEN" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "xraySetting=$modified" \
    --data-urlencode "outboundTestUrl=https://www.google.com/generate_204" \
    -X POST "${API_BASE}/xray/update") || die "Запрос обновления Xray не прошёл"

  jq -e '.success == true' <<<"$resp" >/dev/null 2>&1 || die "Панель отклонила настройки Xray: $resp"

  if [[ "$WARP_MODE" == "yes" ]]; then
    green "Xray настроен: DNS Quad9, маршрут через WARP с fallback на direct"
  else
    green "Xray настроен: DNS Quad9, маршрут напрямую"
  fi
}

add_hysteria2() {
  step "Hysteria2 (UDP/443) и единая подписка"

  local existing
  existing=$(sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE protocol='hysteria' ORDER BY id LIMIT 1;")

  if [[ -n "$existing" ]]; then
    yellow "Hysteria2 inbound уже есть (id=$existing), использую его параметры"
    local settings stream
    settings=$(sqlite3 "$XUI_DB" "SELECT settings FROM inbounds WHERE id=${existing};")
    stream=$(sqlite3 "$XUI_DB" "SELECT stream_settings FROM inbounds WHERE id=${existing};")
    HY_AUTH=$(jq -r '.clients[0].auth' <<<"$settings")
    HY_SUBID=$(jq -r '.clients[0].subId' <<<"$settings")
    HY_OBFS=$(jq -r '.finalmask.udp[0].settings.password' <<<"$stream")
    [[ -n "$HY_AUTH" && "$HY_AUTH" != "null" && -n "$HY_SUBID" && "$HY_SUBID" != "null" ]] \
      || die "Не удалось прочитать параметры существующего Hysteria2 inbound"
  else
    HY_AUTH=$(openssl rand -hex 16)
    HY_OBFS=$(openssl rand -hex 16)
    HY_SUBID=$(openssl rand -hex 8)

    local settings_json stream_json sniffing resp hy_id others others_json client_json resp2
    settings_json=$(jq -nc --arg auth "$HY_AUTH" --arg sub "$HY_SUBID" '{
      version: 2,
      clients: [{
        auth: $auth, email: "default", limitIp: 0, totalGB: 0, expiryTime: 0,
        enable: true, tgId: "", subId: $sub, comment: "default", reset: 0
      }]
    }')

    stream_json=$(jq -nc --arg sni "$DOMAIN" --arg cert "$WEB_CERT" --arg key "$WEB_KEY" --arg obfs "$HY_OBFS" '{
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

    sniffing='{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

    resp=$(curl -ks --max-time 20 \
      -H "Authorization: Bearer $API_TOKEN" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "remark=Hysteria2 UDP/443" \
      --data-urlencode "enable=true" \
      --data-urlencode "listen=" \
      --data-urlencode "port=443" \
      --data-urlencode "protocol=hysteria" \
      --data-urlencode "expiryTime=0" \
      --data-urlencode "settings=$settings_json" \
      --data-urlencode "streamSettings=$stream_json" \
      --data-urlencode "sniffing=$sniffing" \
      "${API_BASE}/inbounds/add") || die "Запрос создания Hysteria2 inbound не прошёл"

    jq -e '.success == true' <<<"$resp" >/dev/null 2>&1 \
      || die "Не удалось создать Hysteria2 inbound: $(jq -r '.msg // .' <<<"$resp" 2>/dev/null | head -c 300)"

    hy_id=$(jq -r '.obj.id' <<<"$resp")
    green "Hysteria2 inbound создан (id=$hy_id)"

    others=$(sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE enable=1 AND id != ${hy_id} ORDER BY id;")
    if [[ -n "$others" ]]; then
      others_json=$(printf '%s\n' "$others" | jq -R . | jq -sc 'map(tonumber)')
      client_json=$(jq -nc --arg sub "$HY_SUBID" '{
        email: "default", subId: $sub, totalGB: 0, expiryTime: 0,
        limitIp: 0, enable: true, tgId: 0, comment: "default", reset: 0
      }')
      resp2=$(curl -ks --max-time 20 \
        -H "Authorization: Bearer $API_TOKEN" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --argjson c "$client_json" --argjson ids "$others_json" '{client: $c, inboundIds: $ids}')" \
        "${API_BASE}/clients/add") || die "Запрос создания клиента не прошёл"
      jq -e '.success == true' <<<"$resp2" >/dev/null 2>&1 \
        || die "Не удалось создать клиента: $(jq -r '.msg // .' <<<"$resp2" 2>/dev/null | head -c 300)"
      green "Клиент подключён к $(wc -l <<<"$others" | tr -d ' ') inbound(ам)"
    fi
  fi

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 443/udp >/dev/null 2>&1 || true
  fi

  SUB_URL="https://${DOMAIN}/${SUB_PATH_T}/${HY_SUBID}"
  HY_LINK="hysteria2://${HY_AUTH}@${DOMAIN}:443/?sni=${DOMAIN}&alpn=h3&obfs=salamander&obfs-password=${HY_OBFS}#$(printf '%s' 'Hysteria2 UDP/443' | jq -sRr @uri)"
}

deploy_clash_template() {
  step "Clash-шаблон"
  local src="$SCRIPT_DIR/assets/clash/clash.yaml"
  local dst="/var/www/subpage/clash.yaml.tpl"

  mkdir -p /var/www/subpage
  if [[ -f "$src" ]]; then
    cp "$src" "$dst"
  else
    curl -fsSL "${REPO_RAW}/assets/clash/clash.yaml" -o "$dst" || die "Не удалось скачать clash.yaml"
  fi

  sed -i "s|\${DOMAIN}|${DOMAIN}|g; s|\${SUB_PATH}|${SUB_PATH_T}|g" "$dst"
  chown -R www-data:www-data /var/www/subpage 2>/dev/null || true
  chmod 644 "$dst"
  green "Шаблон записан в $dst"
}

verify() {
  step "Проверка"

  local code sub server_ip
  code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "https://${DOMAIN}/${PANEL_PATH}/" || true)
  if [[ "$code" == "200" ]]; then
    green "Панель отвечает (HTTP 200)"
  else
    yellow "Панель вернула HTTP ${code:-нет ответа}"
  fi

  sub=$(curl -fsSL --max-time 15 -A "v2rayN/7.0" "$SUB_URL" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null || true)
  if grep -q '^hysteria2://' <<<"$sub"; then
    green "Подписка содержит Hysteria2"
  else
    yellow "Подписка не содержит Hysteria2, проверь inbound и клиента в панели"
  fi

  local udp443
  udp443=$(ss -ulnp 'sport = :443' 2>/dev/null || true)
  if grep -q ':443' <<<"$udp443"; then
    green "Xray слушает UDP/443"
  else
    yellow "UDP/443 не слушается, проверь: systemctl status x-ui"
  fi

  if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    yellow "Глобальный IPv6 всё ещё есть на сервере"
  else
    green "IPv6 на сервере отсутствует"
  fi

  server_ip=$(curl -4 -fsS --max-time 10 https://ipinfo.io/ip || true)
  green "IP сервера: ${server_ip:-неизвестно}"

  if [[ "$WARP_MODE" == "yes" ]]; then
    WARP_IP=$(curl -fsS --max-time 10 --interface wgcf https://ipinfo.io/ip 2>/dev/null || true)
    if [[ -n "$WARP_IP" && "$WARP_IP" != "$server_ip" ]]; then
      green "Выход через WARP: $WARP_IP"
    else
      yellow "WARP не отдаёт внешний IP, клиенты пойдут напрямую (fallback)"
    fi
  fi
}

write_summary() {
  step "Итог"

  local warp_line
  if [[ "$WARP_MODE" == "yes" ]]; then
    warp_line="включён (IP: ${WARP_IP:-не проверен}), при падении WARP трафик идёт напрямую"
  else
    warp_line="не установлен, трафик идёт напрямую"
  fi

  (
    umask 077
    {
      echo "=== 3x-ui-pro + Hysteria2 ==="
      echo "Создано: $(date -Iseconds)"
      echo "Домен: $DOMAIN"
      echo ""
      echo "Панель: https://${DOMAIN}/${PANEL_PATH}/"
      echo "Логин: $PANEL_USER"
      echo "Пароль: $PANEL_PASS"
      echo ""
      echo "Подписка (все протоколы): $SUB_URL"
      echo "Hysteria2 (share link): $HY_LINK"
      echo "Hysteria2 auth: $HY_AUTH"
      echo "Hysteria2 obfs: salamander, пароль: $HY_OBFS"
      echo ""
      echo "DNS: Quad9 DoH (https://dns.quad9.net/dns-query)"
      echo "WARP: $warp_line"
    } > "$HY_CREDS_FILE"
  )

  echo ""
  green "============================================================"
  green "  3x-ui-pro + Hysteria2 установлен"
  green "============================================================"
  echo "Панель   : ${PANEL_URL:-https://${DOMAIN}/${PANEL_PATH}/}"
  echo "Логин    : $PANEL_USER"
  echo "Пароль   : $PANEL_PASS"
  echo ""
  echo "Подписка : $SUB_URL"
  echo "Hysteria2: $HY_LINK"
  echo ""
  echo "WARP     : $warp_line"
  echo ""
  echo "Файлы: $PANEL_CREDS_FILE, $HY_CREDS_FILE"
}

main() {
  preflight
  ask_warp
  install_upstream
  load_panel_creds
  read_xui_settings
  if [[ "$WARP_MODE" == "yes" ]]; then
    install_warp
  else
    disable_warp
  fi
  add_hysteria2
  configure_xray
  deploy_clash_template

  systemctl restart x-ui
  sleep 3
  systemctl is-active --quiet x-ui || die "x-ui не запустился: systemctl status x-ui"

  verify
  write_summary
}

main "$@"
