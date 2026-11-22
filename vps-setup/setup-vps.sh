#!/usr/bin/env bash
#
# Первоначальная настройка VPS на Ubuntu 24.04
#   - базовая система, автообновления, swap
#   - ssh: только ключи, drop-in конфиг вместо правки основного файла
#   - ufw: список портов под будущий VPN
#   - fail2ban: мягкий режим (только sshd)
#   - жёсткий лимит логов 100 МБ (5 уровней защиты)
#   - docker: правила DOCKER-USER, чтобы ufw не обходился
#
# Скрипт идемпотентный: можно запускать повторно.
# Запускать: ./setup-vps.sh (от root)
#
set -Eeuo pipefail

# ============================== ПАРАМЕТРЫ ==============================
SSH_PORT="${SSH_PORT:-22}"                  # порт SSH (не меняем)
ADMIN_IP="${ADMIN_IP:-}"                    # IP, который fail2ban не тронет
PUBKEY="${PUBKEY:-}"                        # публичный SSH-ключ для root
PUBKEY_B64="${PUBKEY_B64:-}"                # альтернатива: base64 от PUBKEY (от bootstrap)

# Порты под VPN. 22/tcp открывается отдельно через `ufw limit`.
TCP_PORTS=(53 80 443 4443 8443)
UDP_PORTS=(53 443 51820)

TOTAL_LOG_LIMIT_MB="${TOTAL_LOG_LIMIT_MB:-100}"   # жёсткий потолок на /var/log
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-60M}"         # SystemMaxUse для journald
JOURNAL_MAX_FILE="${JOURNAL_MAX_FILE:-8M}"        # размер одного файла журнала
LOGROTATE_SIZE="${LOGROTATE_SIZE:-2M}"            # порог ротации обычных логов
LOGROTATE_ROTATE="${LOGROTATE_ROTATE:-3}"         # сколько поколений хранить
SWAP_SIZE="${SWAP_SIZE:-2G}"

BACKUP_DIR="/root/vps-setup-backup-$(date +%Y%m%d-%H%M%S)"
# =======================================================================

log()  { printf '\033[0;32m[OK]\033[0m   %s\n' "$*"; }
info() { printf '\033[0;36m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
on_err() { local rc=$?; warn "строка $1, код $rc"; exit "$rc"; }
trap 'on_err $LINENO' ERR

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

backup() {
  if [ -e "$1" ]; then
    cp -a "$1" "$BACKUP_DIR/$(printf '%s' "$1" | tr '/' '_')"
  fi
}

# ------------------------------ проверки ------------------------------
[ "$(id -u)" -eq 0 ] || die "Запускать от root"
[ -d /etc/ssh ] || die "Это не Ubuntu-сервер (нет /etc/ssh)"
mkdir -p "$BACKUP_DIR"
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
    warn "Ожидался Ubuntu 24.04, а тут ${PRETTY_NAME:-неизвестно}. Продолжаю."
  fi
fi

if [ -z "$ADMIN_IP" ] && [ -n "${SSH_CONNECTION:-}" ]; then
  ADMIN_IP="${SSH_CONNECTION%% *}"
fi
[ -n "$ADMIN_IP" ] || warn "ADMIN_IP не определён — fail2ban будет банить всех подряд."

# bootstrap шлёт ключ в base64, чтобы не ломаться на кавычках
if [ -z "$PUBKEY" ] && [ -n "$PUBKEY_B64" ]; then
  # Убираем trailing newline, иначе grep -F не найдёт уже добавленный ключ
  # и authorized_keys будет разрастаться дубликатами при повторных запусках.
  PUBKEY="$(printf '%s' "$PUBKEY_B64" | base64 -d | tr -d '\n\r')" || warn "не удалось декодировать PUBKEY_B64"
fi

# --------------------------- 1. пакеты --------------------------------
step "1/9  Пакеты и базовая система"
export DEBIAN_FRONTEND=noninteractive
# force-confold / force-confdef: не спрашивать про изменённые конфиги,
# всегда сохранять текущую версию (как если бы пользователь нажал N).
APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt-get update -qq
apt-get "${APT_OPTS[@]}" --no-install-recommends install \
  ca-certificates curl gnupg lsof dnsutils jq htop logrotate \
  ufw fail2ban unattended-upgrades chrony rsyslog
apt-get "${APT_OPTS[@]}" full-upgrade
apt-get "${APT_OPTS[@]}" autoremove
log "пакеты установлены, система обновлена"

# своп. btrfs/xfs не умеют fallocate под своп — там dd.
# Для btrfs отключаем CoW на файле свопа, иначе btrfs с ним плохо дружит.
if ! swapon --show=NAME --noheadings | grep -q .; then
  root_fs="$(stat -f -c %T / 2>/dev/null || echo unknown)"
  size_bytes="$(numfmt --from=iec "$SWAP_SIZE" 2>/dev/null || echo 2147483648)"
  count=$(( size_bytes / 1048576 ))
  case "$root_fs" in
    btrfs)
      truncate -s 0 /swapfile
      chattr +C /swapfile 2>/dev/null || true
      dd if=/dev/zero of=/swapfile bs=1M count="$count" status=none ;;
    xfs)
      dd if=/dev/zero of=/swapfile bs=1M count="$count" status=none ;;
    *)
      fallocate -l "$SWAP_SIZE" /swapfile ;;
  esac
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  log "своп $SWAP_SIZE создан (фс: $root_fs)"
else
  info "своп уже есть, пропускаю"
fi

if [ -n "${TZ_OVERRIDE:-}" ]; then
  timedatectl set-timezone "$TZ_OVERRIDE"
  log "часовой пояс: $TZ_OVERRIDE"
else
  info "часовой пояс не трогаю (текущий: $(timedatectl show -p Timezone --value 2>/dev/null || echo '?'))"
  info "задать свой: TZ_OVERRIDE=Europe/Moscow ./setup-vps.sh"
fi
systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true

# --------------------------- 2. sysctl --------------------------------
step "2/9  Параметры ядра"
install -d -m 0755 /etc/sysctl.d
backup /etc/sysctl.d/99-vps.conf
cat > /etc/sysctl.d/99-vps.conf <<'SYSCTL'
# --- базовая защита сети ---
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# --- форвардинг: нужен WireGuard / Xray / X-UI ---
net.ipv4.ip_forward = 1
# IPv6 forwarding intentionally left unset: IPv6 is disabled in this setup.

# --- rp_filter выключен: ломает WireGuard и tun-интерфейсы ---
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# --- сокеты и буферы (xray/warp любят большие соединения) ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
fs.file-max = 200000
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288

# --- не выкидывать страницы в своп: память важнее ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50
SYSCTL
sysctl --system >/dev/null
log "sysctl применены"

# --------------------- 2a. отключение IPv6 -----------------------------
# Сервер работает в IPv4-only режиме: это предотвращает утечки IPv6 как
# со стороны клиентов, так и со стороны самого сервера.
step "2a/9  Отключение IPv6"

# 1) Ядро: отключаем IPv6 глобально и на всех интерфейсах.
#    Предварительно ищем и комментируем конфликтующие строки, иначе более
#    поздние по порядку применения файлы (например, /etc/sysctl.conf)
#    могут включить IPv6 обратно.
install -d -m 0755 /etc/sysctl.d

# Файлы, в которых ищем IPv6-настройки. /etc/sysctl.conf важен, т.к.
# sysctl --system применяет его в самом конце.
IPV6_SYSCTL_FILES=(/etc/sysctl.d/*.conf /etc/sysctl.conf)

for f in "${IPV6_SYSCTL_FILES[@]}"; do
  [ -f "$f" ] || continue
  # Пропускаем свой будущий файл — он будет перезаписан ниже.
  [[ "$f" == "/etc/sysctl.d/99-disable-ipv6.conf" ]] && continue

  # Комментируем строки, которые явно включают IPv6 или могут
  # противоречить отключению: disable_ipv6=0, accept_ra=1/2,
  # autoconf=1, forwarding=1, use_tempaddr и т.п.
  if grep -qE '^[[:space:]]*net\.ipv6\.' "$f"; then
    backup "$f"
    sed -Ei \
      -e 's|^[[:space:]]*(net\.ipv6\.conf\..*\.disable_ipv6[[:space:]]*=[[:space:]]*0)|# DISABLED-BY-VPS-SETUP \1|' \
      -e 's|^[[:space:]]*(net\.ipv6\.conf\..*\.accept_ra[[:space:]]*=[[:space:]]*[12])|# DISABLED-BY-VPS-SETUP \1|' \
      -e 's|^[[:space:]]*(net\.ipv6\.conf\..*\.autoconf[[:space:]]*=[[:space:]]*1)|# DISABLED-BY-VPS-SETUP \1|' \
      -e 's|^[[:space:]]*(net\.ipv6\.conf\..*\.forwarding[[:space:]]*=[[:space:]]*1)|# DISABLED-BY-VPS-SETUP \1|' \
      -e 's|^[[:space:]]*(net\.ipv6\.conf\.all\.forwarding[[:space:]]*=[[:space:]]*1)|# DISABLED-BY-VPS-SETUP \1|' \
      -e 's|^[[:space:]]*(net\.ipv6\.conf\..*\.use_tempaddr[[:space:]]*=[[:space:]]*.)|# DISABLED-BY-VPS-SETUP \1|' \
      "$f"
    log "прочищены IPv6-настройки в $f"
  fi
done

backup /etc/sysctl.d/99-disable-ipv6.conf
cat > /etc/sysctl.d/99-disable-ipv6.conf <<'IPV6SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
IPV6SYSCTL
sysctl --system >/dev/null

# Проверка результата: IPv6 должен быть выключен на всех интерфейсах.
# Если какой-то интерфейс остался включённым, отключаем его принудительно и
# фиксируем в 99-disable-ipv6.conf, чтобы после перезагрузки настройка не слетела.
list_ipv6_enabled() {
  local f
  for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [ -e "$f" ] || continue
    if [ "$(cat "$f")" = "0" ]; then
      basename "$(dirname "$f")"
    fi
  done
}

enabled_ifaces="$(list_ipv6_enabled)"
if [ -n "$enabled_ifaces" ]; then
  warn "IPv6 включён на: $(echo "$enabled_ifaces" | tr '\n' ' ')— отключаю принудительно"
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    printf 'net/ipv6/conf/%s/disable_ipv6 = 1\n' "$iface" >> /etc/sysctl.d/99-disable-ipv6.conf
    echo 1 > "/proc/sys/net/ipv6/conf/${iface}/disable_ipv6" || true
  done <<< "$enabled_ifaces"
  sysctl --system >/dev/null
  enabled_ifaces="$(list_ipv6_enabled)"
  if [ -n "$enabled_ifaces" ]; then
    die "IPv6 не удалось отключить на: $(echo "$enabled_ifaces" | tr '\n' ' ')"
  fi
fi
log "IPv6 выключен на всех интерфейсах"

# Юнит, который выставляет disable_ipv6=1 на каждой загрузке. Нужен, потому что
# systemd-networkd может снова включить IPv6 на интерфейсе при настройке сети.
cat > /etc/systemd/system/ipv6-disable.service <<'IPV6UNIT'
[Unit]
Description=Force IPv6 off on all interfaces
After=network-online.target systemd-networkd-wait-online.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do echo 1 > $$f; done"

[Install]
WantedBy=multi-user.target
IPV6UNIT
systemctl daemon-reload
systemctl enable --now ipv6-disable.service >/dev/null 2>&1 || warn "не удалось включить ipv6-disable.service"

# 2) Cloud-init: запрещаем ему перезаписывать сетевую конфигурацию.
install -d -m 0755 /etc/cloud/cloud.cfg.d
backup /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'CLOUDCFG'
network: {config: disabled}
CLOUDCFG

# 3) Netplan: отключаем DHCPv6 и Router Advertisement на основном интерфейсе.
#    Применится при перезагрузке: netplan apply в SSH-сессии может её оборвать.
DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$DEFAULT_IFACE" ] || die "Не удалось определить основной сетевой интерфейс"
DEFAULT_MAC=$(cat "/sys/class/net/${DEFAULT_IFACE}/address")

if command -v netplan >/dev/null 2>&1 && [ -d /etc/netplan ]; then
  # Провайдер может прописать IPv6 статически (addresses/routes/nameservers) в
  # своём netplan-файле. Списки netplan объединяются, поэтому dhcp6/accept-ra
  # его не отменяют — IPv6-часть нужно убрать из самого файла.
  for np in /etc/netplan/*.yaml; do
    [ -f "$np" ] || continue
    grep -q ':' "$np" 2>/dev/null || continue
    if python3 - "$np" <<'PYSTRIP'
import sys, yaml
p = sys.argv[1]
d = yaml.safe_load(open(p)) or {}
eths = (d.get("network") or {}).get("ethernets") or {}
changed = False
for name, e in eths.items():
    if not isinstance(e, dict):
        continue
    if "addresses" in e:
        keep = [a for a in e["addresses"] if ":" not in str(a)]
        changed |= keep != e["addresses"]; e["addresses"] = keep
    if "routes" in e:
        keep = [r for r in e["routes"] if ":" not in str(r.get("via", ""))]
        changed |= keep != e["routes"]; e["routes"] = keep
    ns = (e.get("nameservers") or {}).get("addresses")
    if ns:
        keep = [a for a in ns if ":" not in str(a)]
        changed |= keep != ns; e["nameservers"]["addresses"] = keep
if changed:
    yaml.safe_dump(d, open(p, "w"), default_flow_style=False, sort_keys=False)
    sys.exit(0)
sys.exit(1)
PYSTRIP
    then
      backup "$np"
      warn "Удалены статические IPv6-адреса из $np (провайдер)"
    fi
  done

  backup /etc/netplan/99-disable-ipv6.yaml
  cat > /etc/netplan/99-disable-ipv6.yaml <<EOF
network:
  version: 2
  ethernets:
    ${DEFAULT_IFACE}:
      match:
        macaddress: ${DEFAULT_MAC}
      dhcp6: false
      accept-ra: false
      link-local: []
EOF
  chmod 600 /etc/netplan/99-disable-ipv6.yaml
  if ! netplan generate >/dev/null 2>&1; then
    rm -f /etc/netplan/99-disable-ipv6.yaml
    warn "netplan generate не прошёл — файл удалён, IPv6 отключён только через sysctl"
  fi
fi

log "IPv6 отключён через sysctl (интерфейс ${DEFAULT_IFACE})"
warn "Перезагрузите сервер: netplan и cloud-init применяются при загрузке"

# --------------------- 3. автообновления ------------------------------
step "3/9  Автоматические обновления безопасности"
backup /etc/apt/apt.conf.d/20auto-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AU'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AU

backup /etc/apt/apt.conf.d/52unattended-upgrades-local
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'AUL'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Mail "root";
AUL

systemctl enable --now unattended-upgrades
log "unattended-upgrades включён (авто-ребут выключен намеренно)"

# --------------------- 4. SSH-ключ для root ---------------------------
step "4/9  SSH-ключ для root"
install -d -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys

if [ -n "$PUBKEY" ]; then
  grep -qF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$PUBKEY" >> /root/.ssh/authorized_keys
  log "публичный ключ добавлен для root"
else
  warn "PUBKEY не передан — ключ на сервер не скопирован"
fi

# Защита от самоблокировки: парольный вход отключаем только при наличии SSH-ключа
if ! grep -qE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys 2>/dev/null; then
  die "В /root/.ssh/authorized_keys нет SSH-ключей — парольный вход не отключаю. Передай PUBKEY или PUBKEY_B64 и запусти снова"
fi

# --------------------- 5. sshd ----------------------------------------
step "5/9  Hardening SSH (порт $SSH_PORT, только ключи)"

# sshd использует ПЕРВОЕ встреченное значение директивы. Провайдеры любят
# прописывать PasswordAuthentication yes в /etc/ssh/sshd_config.d/50-cloud-init.conf
# или даже внутри Match-блока. Чтобы гарантированно выиграть:
#   1) комментируем конфликтующие строки ВО ВСЕХ файлах sshd;
#   2) вставляем наш блок в самое начало /etc/ssh/sshd_config — раньше любого Include.

# Бэкапы для отката, если sshd -T не покажет нужные значения ДО reload.
# Это защита от блокировки: при ошибке sshd останется со старым рабочим конфигом.
SSHD_BACKUP_SUFFIX=".vps-backup-$(date +%s)"
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config$SSHD_BACKUP_SUFFIX"
for f in /etc/ssh/sshd_config.d/*.conf; do
  [ -f "$f" ] && cp "$f" "$f$SSHD_BACKUP_SUFFIX"
done

restore_sshd() {
  cp "/etc/ssh/sshd_config$SSHD_BACKUP_SUFFIX" /etc/ssh/sshd_config
  for f in /etc/ssh/sshd_config.d/*.conf"$SSHD_BACKUP_SUFFIX"; do
    [ -f "$f" ] || continue
    orig="${f%"$SSHD_BACKUP_SUFFIX"}"
    cp "$f" "$orig"
  done
  if systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl reload sshd || true
  elif systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl reload ssh || true
  else
    systemctl restart ssh 2>/dev/null || true
  fi
  rm -f "/etc/ssh/sshd_config$SSHD_BACKUP_SUFFIX" /etc/ssh/sshd_config.d/*.conf"$SSHD_BACKUP_SUFFIX"
}

# Удаляем свой предыдущий блок, если скрипт уже запускался
sed -i '/^# BEGIN VPS-HARDENING$/,/^# END VPS-HARDENING$/d' /etc/ssh/sshd_config

# Предупреждаем, если провайдер оставил Match-блоки: мы закомментируем
# внутренние директивы аутентификации, и логика Match может перестать работать.
if grep -qEi '^[[:space:]]*Match[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
  warn "найдены Match-блоки в sshd; их директивы аутентификации будут закомментированы"
fi

# Комментируем конфликтующие строки в основном файле и во всех drop-in'ах
for sshd_cfg in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
  [ -f "$sshd_cfg" ] || continue
  backup "$sshd_cfg"
  sed -i -E \
    -e 's/^[[:space:]]*(PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin|PermitEmptyPasswords|AllowUsers)[[:space:]]+/# &/' \
    "$sshd_cfg"
done

# Вставляем наш блок в начало основного файла
tmp_cfg="$(mktemp)"
{
  cat <<'SSHD'
# BEGIN VPS-HARDENING
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
UsePAM yes
MaxAuthTries 3
MaxSessions 8
LoginGraceTime 30
AllowAgentForwarding no
X11Forwarding no
AllowTcpForwarding yes
PermitTunnel no
ClientAliveInterval 300
ClientAliveCountMax 2
PrintMotd no
PrintLastLog yes
AllowUsers root
# END VPS-HARDENING

SSHD
  cat /etc/ssh/sshd_config
} > "$tmp_cfg"
cat "$tmp_cfg" > /etc/ssh/sshd_config
rm -f "$tmp_cfg"

# sshd -t и sshd -T требуют /run/sshd. Он создаётся при старте сервиса,
# но на свежих/минимальных образах может отсутствовать до первого запуска.
for d in /run/sshd /var/run/sshd; do
  if [ ! -d "$d" ]; then
    systemd-tmpfiles --create --prefix "$d" 2>/dev/null || true
    if [ ! -d "$d" ]; then
      mkdir -p "$d"
      chmod 0755 "$d"
      chown root:root "$d"
      info "создан каталог $d для sshd"
    fi
  fi
done

# Проверяем эффективный конфиг ДО reload. Если не сходится — откат и выход.
if ! sshd -t; then
  warn "конфиг sshd невалиден после наших изменений — откатываю"
  restore_sshd
  die "конфиг sshd невалиден"
fi

sshd_check="$(sshd -T)"
if ! printf '%s\n' "$sshd_check" | grep -qi '^passwordauthentication no'; then
  warn "PasswordAuthentication не выключился:"
  printf '%s\n' "$sshd_check" | grep -Ei 'passwordauth|pubkeyauth|permitroot|allowusers|match' | sed 's/^/  /'
  grep -nEi 'passwordauth|pubkeyauth|permitroot|allowusers|match' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sed 's/^/  /' || true
  restore_sshd
  die "PasswordAuthentication всё ещё yes — проверь вывод выше"
fi
if ! printf '%s\n' "$sshd_check" | grep -qi '^pubkeyauthentication yes'; then
  warn "PubkeyAuthentication не включился:"
  printf '%s\n' "$sshd_check" | grep -Ei 'passwordauth|pubkeyauth|permitroot|allowusers|match' | sed 's/^/  /'
  grep -nEi 'passwordauth|pubkeyauth|permitroot|allowusers|match' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sed 's/^/  /' || true
  restore_sshd
  die "PubkeyAuthentication не включился — проверь вывод выше"
fi
# В разных версиях OpenSSH canonical-значение может быть prohibit-password
# или without-password — семантически это одно и то же (root только по ключу).
if ! printf '%s\n' "$sshd_check" | grep -qiE '^permitrootlogin[[:space:]]+(prohibit-password|without-password)$'; then
  warn "PermitRootLogin не равен prohibit-password/without-password:"
  printf '%s\n' "$sshd_check" | grep -Ei 'permitrootlogin' | sed 's/^/  /'
  restore_sshd
  die "PermitRootLogin не prohibit-password — проверь вывод выше"
fi

# Только после успешной проверки перезагружаем sshd.
# На некоторых образах сервис называется ssh (socket-activation), а не sshd.
if systemctl is-active --quiet sshd 2>/dev/null; then
  systemctl reload sshd
elif systemctl is-active --quiet ssh 2>/dev/null; then
  systemctl reload ssh
else
  systemctl restart ssh
fi
log "sshd перечитан (reload, соединения не рвутся)"
log "проверено: вход только по ключу, порт $(printf '%s\n' "$sshd_check" | awk '/^port /{print $2}')"

# Убираем бэкапы — откат больше не нужен
rm -f "/etc/ssh/sshd_config$SSHD_BACKUP_SUFFIX" /etc/ssh/sshd_config.d/*.conf"$SSHD_BACKUP_SUFFIX"

# --------------------- 6. ufw ----------------------------------------
step "6/9  UFW"
# IPv6 отключён на уровне ядра, поэтому ufw не управляет IPv6-правилами.
if [ -f /etc/default/ufw ]; then
  backup /etc/default/ufw
  if grep -q '^IPV6=' /etc/default/ufw; then
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  else
    printf 'IPV6=no\n' >> /etc/default/ufw
  fi
  if grep -q '^DEFAULT_INPUT_POLICY=' /etc/default/ufw; then
    sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' /etc/default/ufw
  else
    printf 'DEFAULT_INPUT_POLICY="DROP"\n' >> /etc/default/ufw
  fi
fi

if ufw status 2>/dev/null | grep -q '^Status: active'; then
  warn "ufw уже активен и содержит правила — сбрасываю их все"
fi
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
# Docker и VPN сами вставляют правила форвардинга; потолок входящего трафика
# держит DOCKER-USER + ufw input. deny routed здесь сломал бы Docker.
ufw default allow routed

# SSH первым и с rate-limit, иначе можно отрезать себя от сервера
ufw limit "$SSH_PORT/tcp" comment 'SSH'
for p in "${TCP_PORTS[@]}"; do
  ufw allow "$p/tcp" comment "tcp-$p"
done
for p in "${UDP_PORTS[@]}"; do
  ufw allow "$p/udp" comment "udp-$p"
done

ufw logging low
ufw --force enable
log "UFW включён, порты: tcp $SSH_PORT(limit) ${TCP_PORTS[*]} / udp ${UDP_PORTS[*]}"

# --------------------- 7. fail2ban -----------------------------------
step "7/9  Fail2ban (мягкий режим)"
install -d -m 0755 /etc/fail2ban/jail.d
backup /etc/fail2ban/jail.d/60-vps.local

# ignoreip: локалка, приватные сети и наш IP — чтобы себя не забанить
IGNOREIP="127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
if [ -n "$ADMIN_IP" ]; then
  IGNOREIP="$IGNOREIP $ADMIN_IP"
  log "в ignoreip добавлен $ADMIN_IP"
fi

cat > /etc/fail2ban/jail.d/60-vps.local <<F2B
[DEFAULT]
bantime  = 1h
findtime = 15m
maxretry = 8
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1d
backend  = auto
banaction = ufw
banaction_allports = ufw
ignoreip = $IGNOREIP
dbpurgeage = 7d
loglevel  = INFO
logtarget = /var/log/fail2ban.log

[sshd]
enabled  = true
port     = ssh
mode     = normal
maxretry = 8
findtime = 15m
bantime  = 1h

# Всё лишнее выключаем: агрессивные jail'ы и есть источник тысяч записей
[nginx-http-auth] enabled = false
[nginx-botsearch]  enabled = false
[nginx-limit-req]  enabled = false
[nginx-common]     enabled = false
[apache-auth]      enabled = false
[apache-badbots]   enabled = false
[recidive]         enabled = false
[postfix]          enabled = false
[dovecot]          enabled = false
[openldap]         enabled = false
[sssd]             enabled = false
[django]           enabled = false
[proxmox]          enabled = false
[transmission]     enabled = false
[pure-ftpd]        enabled = false
[asterisk]         enabled = false
[bind]             enabled = false
[docker-registry]  enabled = false
[phpmyadmin]       enabled = false
[postgresql]       enabled = false
[kerberos]         enabled = false
F2B

if ! fail2ban-client -t >/dev/null 2>&1; then
  fail2ban-client -t || true
  die "конфиг fail2ban невалиден"
fi

# ufw reset выше стёр и текущие баны — снимаем их и в базе fail2ban,
# иначе ip будет числиться забаненным, но правила уже не применены.
fail2ban-client unban --all >/dev/null 2>&1 || true
systemctl enable --now fail2ban
systemctl restart fail2ban
sleep 3
fail2ban-client status sshd 2>/dev/null | sed 's/^/     /' || warn "jail sshd не поднялся"
log "fail2ban: maxretry=8, findtime=15m, bantime=1h с ростом, только sshd"

# --------------------- 8. лимиты логов -------------------------------
step "8/9  Ограничение логов (потолок ${TOTAL_LOG_LIMIT_MB} МБ)"

# --- 8.1 journald ---
install -d -m 0755 /etc/systemd/journald.conf.d
backup /etc/systemd/journald.conf.d/60-vps-limits.conf
cat > /etc/systemd/journald.conf.d/60-vps-limits.conf <<JD
[Journal]
Storage=persistent
Compress=yes
Seal=yes
SystemMaxUse=$JOURNAL_MAX_USE
SystemMaxFileSize=$JOURNAL_MAX_FILE
SystemMaxFiles=7
MaxRetentionSec=7d
RateLimitIntervalSec=30s
RateLimitBurst=2000
JD
systemd-tmpfiles --create --prefix /var/log/journal || true
systemctl restart systemd-journald
log "journald: потолок $JOURNAL_MAX_USE, retention 7 дней, rate-limit 2000/30s"

# --- 8.2 logrotate: переводим «daily/weekly» на «size» ---
# Ubuntu-конфиги оставляем на месте (тогда apt их обновляет), но меняем
# триггер ротации: иначе за сутки лог вырастет выше лимита.
# Трансформация целиком на awk — POSIX-классы в sed ведут себя по-разному
# на macOS и Linux, а этот кусок приходится гонять и там, и там.
tune_logrotate() {
  local f="$1" size="$2" rotate="$3" tmp
  [ -f "$f" ] || return 0
  if ! grep -q '{' "$f" || ! grep -q '}' "$f"; then
    warn "в $f не найден блок конфига, пропускаю"
    return 0
  fi
  backup "$f"
  tmp="$(mktemp)"
  awk -v size="$size" -v rot="$rotate" '
    /^[ \t]*(daily|weekly|monthly|yearly|minsize|maxsize)[ \t]/ { next }
    /^[ \t]*(daily|weekly|monthly|yearly)[ \t]*$/          { next }
    /^[ \t]*rotate[ \t]+[0-9]+[ \t]*$/                     { next }
    /^[ \t]*size[ \t]+[0-9]+[kKmMgG]?[ \t]*$/              { next }
    # Блок может начинаться как "{" на отдельной строке, так и "/path {"
    /{/ && !in_block {
      print
      print "    size " size
      print "    rotate " rot
      in_block=1
      next
    }
    /}/ { in_block=0 }
    { print }
  ' "$f" > "$tmp"
  [ -s "$tmp" ] || { warn "awk-трансформация $f дала пустой результат, оставляю как есть"; rm -f "$tmp"; return 0; }
  cat "$tmp" > "$f"
  rm -f "$tmp"
}
tune_logrotate /etc/logrotate.d/rsyslog "$LOGROTATE_SIZE" "$LOGROTATE_ROTATE"
tune_logrotate /etc/logrotate.d/fail2ban "$LOGROTATE_SIZE" "$LOGROTATE_ROTATE"
tune_logrotate /etc/logrotate.d/wtmp 1M 2
log "logrotate: rsyslog/fail2ban/wtmp переведены на size-триггер"

if ! logrotate --debug /etc/logrotate.conf >/dev/null 2>&1; then
  warn "logrotate --debug ругнулся; проверяю точечно:"
  for f in /etc/logrotate.d/rsyslog /etc/logrotate.d/fail2ban /etc/logrotate.d/wtmp /etc/logrotate.d/vps-extras; do
    logrotate --debug "$f" >/dev/null 2>&1 || warn "  битый: $f"
  done
fi

# --- 8.3 прочие приложения (warp-cli пишет мимо journald) ---
cat > /etc/logrotate.d/vps-extras <<EOF
/var/log/warp-svc.log
/var/log/warp/*.log
/var/log/dmesg
/var/log/vps-setup.log
{
    su root adm
    size $LOGROTATE_SIZE
    rotate $LOGROTATE_ROTATE
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
log "logrotate: warp/cloud-init/dmesg под ${LOGROTATE_SIZE}"

# --- 8.4 tmpfiles не используем ---
# Менять владельца/права /var/log рискованно; у нас уже 3 уровня:
# journald vacuum, size-logrotate, watchdog-таймер.

# --- 8.5 watchdog: жёсткий потолок, если что-то вылезло за лимит ---
install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/vps-log-maintenance <<'MAINT'
#!/usr/bin/env bash
# Жёсткий лимит на /var/log. Запускает systemd-таймер vps-log-maintenance.timer
set -uo pipefail

# Плейсхолдер __LIMIT_MB__ подставляется ниже через sed.
# Держим его в отдельной переменной, а не внутри "${...}M" — иначе после
# подстановки получится "${100}M", и bash примет 100 за позиционный параметр.
LIMIT_MB=__LIMIT_MB__
LIMIT_BYTES=$(( LIMIT_MB * 1024 * 1024 ))

total_bytes() { du -sk /var/log 2>/dev/null | awk '{print $1*1024}'; }

# 1) поджать журнал systemd до лимита
journalctl --vacuum-size="${LIMIT_MB}M" --vacuum-time=7d >/dev/null 2>&1 || true

# 2) применить size-ротацию ко всем конфигам
[ -d /var/lib/logrotate ] && logrotate /etc/logrotate.conf >/dev/null 2>&1 || true

# 3) если всё ещё больше лимита — срезать самые жирные .log (последний рубеж)
#    Кандидатов собираем ОДИН раз и сортируем по убыванию размера: если искать
#    find'ом в каждой итерации, получим O(n^2) и десятки секунд на ровном месте.
#    Порядок «сначала крупные» и есть мягкость: мелкие файлы не трогаем, пока
#    есть что урезать покрупнее.
candidates="$(
  find /var/log -xdev -type f -name '*.log' -size +0 2>/dev/null |
  while IFS= read -r f; do
    printf '%s\t%s\n' "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" "$f"
  done | sort -rn | cut -f2-
)"

cur="$(total_bytes)"; cur="${cur:-0}"
trimmed=0
while [ "$cur" -gt "$LIMIT_BYTES" ]; do
  victim=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -s "$f" ] || continue      # пустые пропускаем: обрезать нечего
    victim="$f"
    break
  done <<EOF
$candidates
EOF
  [ -n "$victim" ] || break
  : > "$victim" || break
  cur="$(total_bytes)"; cur="${cur:-0}"
  trimmed=$((trimmed + 1))
  [ "$trimmed" -ge 500 ] && break
done

cur_mb=$(( ${cur:-0} / 1024 / 1024 ))
if [ "$cur_mb" -gt "$LIMIT_MB" ]; then
  logger -t vps-log-maintenance "ВНИМАНИЕ: /var/log = ${cur_mb} МБ, лимит ${LIMIT_MB} МБ, обрезано файлов: $trimmed"
else
  logger -t vps-log-maintenance "/var/log = ${cur_mb} МБ (лимит ${LIMIT_MB} МБ), обрезано файлов: $trimmed"
fi
MAINT
sed -i "s/__LIMIT_MB__/$TOTAL_LOG_LIMIT_MB/g" /usr/local/sbin/vps-log-maintenance
chmod 0755 /usr/local/sbin/vps-log-maintenance

cat > /etc/systemd/system/vps-log-maintenance.service <<'SVC'
[Unit]
Description=Ограничение размера логов (жёсткий лимит)
After=systemd-journald.service rsyslog.service fail2ban.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-log-maintenance
SVC

cat > /etc/systemd/system/vps-log-maintenance.timer <<'TMR'
[Unit]
Description=Периодический контроль размера логов (каждые 2 часа)

[Timer]
OnBootSec=5min
OnUnitActiveSec=2h
AccuracySec=5min
Persistent=true

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now vps-log-maintenance.timer
/usr/local/sbin/vps-log-maintenance || warn "первый прогон watchdog дал ошибку"
log "watchdog логов запущен, потолок ${TOTAL_LOG_LIMIT_MB} МБ"

# --------------------- 9. docker + отчёт -----------------------------
step "9/9  Docker: обход UFW и лимиты логов контейнеров"

# Список портов храним отдельно — его читает и ufw-правила, и DOCKER-USER
{
  printf '# Порты, разрешённые пробрасывать через Docker (DOCKER-USER).\n'
  printf '# Держи в синхроне с правилами ufw.\n'
  printf 'TCP_PORTS="%s"\n' "22 ${TCP_PORTS[*]}"
  printf 'UDP_PORTS="%s"\n' "${UDP_PORTS[*]}"
} > /etc/vps-firewall-ports.conf

install -d -m 0755 /etc/docker
backup /etc/docker/daemon.json
cat > /etc/docker/daemon.json <<'DOCKERJSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "5m",
    "max-file": "2"
  },
  "live-restore": true
}
DOCKERJSON
log "docker daemon.json: логи контейнеров ограничены 5m x 2 = 10 МБ на контейнер"

cat > /usr/local/sbin/docker-ufw-apply <<'DUA'
#!/usr/bin/env bash
# Правила DOCKER-USER. Без них Docker пробрасывает порты мимо ufw,
# и `ufw status` не отражает реальную картину.
#
# Важно: Docker делает DNAT в PREROUTING, поэтому к моменту прохождения
# DOCKER-USER (filter/FORWARD) destination port уже заменён на порт
# контейнера. Чтобы фильтровать по внешнему порту, используем
# conntrack --ctorigdstport, который хранит оригинальный порт до NAT.
set -uo pipefail
CONF=/etc/vps-firewall-ports.conf
[ -r "$CONF" ] || { echo "нет $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
CHAIN=DOCKER-USER
SUBNETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"

iptables -w 10 -N "$CHAIN" 2>/dev/null || true
iptables -w 10 -F "$CHAIN"

iptables -w 10 -A "$CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -w 10 -A "$CHAIN" -i lo -j RETURN
for n in $SUBNETS; do
  iptables -w 10 -A "$CHAIN" -s "$n" -j RETURN
done
# Разрешаем входящий трафик на проброшенные Docker-порты по ОРИГИНАЛЬНОМУ
# порту назначения (до DNAT).
for p in $TCP_PORTS; do
  iptables -w 10 -A "$CHAIN" -p tcp -m conntrack --ctstate DNAT --ctorigdstport "$p" -j RETURN
done
for p in $UDP_PORTS; do
  iptables -w 10 -A "$CHAIN" -p udp -m conntrack --ctstate DNAT --ctorigdstport "$p" -j RETURN
done
iptables -w 10 -A "$CHAIN" -j DROP
logger -t docker-ufw "DOCKER-USER обновлён: tcp=[$TCP_PORTS] udp=[$UDP_PORTS]"
DUA
chmod 0755 /usr/local/sbin/docker-ufw-apply

cat > /etc/systemd/system/docker-ufw.service <<'DUS'
[Unit]
Description=Применение правил DOCKER-USER поверх UFW
After=docker.service ufw.service
Wants=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/docker-ufw-apply
ExecReload=/usr/local/sbin/docker-ufw-apply

[Install]
WantedBy=docker.service
DUS

systemctl daemon-reload
if command -v docker >/dev/null 2>&1; then
  systemctl restart docker || warn "не удалось перезапустить docker"
  systemctl enable --now docker-ufw.service 2>/dev/null || /usr/local/sbin/docker-ufw-apply
  log "правила DOCKER-USER применены"
else
  warn "docker не установлен — правила заработают при первой установке"
  info "перед установкой: apt install docker.io && systemctl start docker-ufw"
fi

# ------------------------------ отчёт ---------------------------------
step "Итог"
{
  echo "=== VPS setup, $(date -Is) ==="
  echo
  echo "-- открытые порты --"
  ss -tulpnH 2>/dev/null | awk '{print $1, $5, $7}' | sort -u || true
  echo
  echo "-- ufw --"
  ufw status verbose
  echo
  echo "-- fail2ban --"
  fail2ban-client status sshd 2>/dev/null || true
  echo
  echo "-- размер логов --"
  journalctl --disk-usage || true
  du -sh /var/log
  echo "лимит: ${TOTAL_LOG_LIMIT_MB} МБ"
  echo
  echo "-- swap --"
  swapon --show || true
  echo
  echo "-- бэкапы исходных конфигов --"
  ls -1 "$BACKUP_DIR" 2>/dev/null || true
} > /root/vps-setup-report.txt 2>&1

cat /root/vps-setup-report.txt
echo
log "готово. отчёт: /root/vps-setup-report.txt, бэкапы: $BACKUP_DIR"
echo
printf '\033[1;33mПроверь в новом окне терминала вход по ключу:\033[0m\n'
printf '  ssh root@<ip-сервера>\n'
echo "Не закрывай текущую сессию, пока не убедишься."
