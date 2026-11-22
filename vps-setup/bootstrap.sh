#!/usr/bin/env bash
#
# Локальный скрипт. Копирует SSH-ключ на VPS, заливает и запускает setup-vps.sh.
#
# Использование:
#   ./bootstrap.sh root@1.2.3.4
#   ./bootstrap.sh root@1.2.3.4 ~/.ssh/id_ed25519
#   ./bootstrap.sh root@1.2.3.4 ~/.ssh/id_ed25519 --key-only
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup-vps.sh"
REMOTE_DIR="/root/vps-setup"

KEY_PATH=""
KEY_ONLY=0
REINSTALL=0
TARGET=""

log()  { printf '\033[0;32m[OK]\033[0m   %s\n' "$*"; }
info() { printf '\033[0;36m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

usage() {
  cat <<'USAGE'
Первоначальная настройка VPS (Ubuntu 24.04)

  ./bootstrap.sh root@1.2.3.4
  ./bootstrap.sh root@1.2.3.4 ~/.ssh/id_ed25519
  ./bootstrap.sh root@1.2.3.4 ~/.ssh/id_ed25519 --key-only
  ./bootstrap.sh root@1.2.3.4 ~/.ssh/id_ed25519 --reinstall

  root@ip     сервер (до настройки нужен пароль root, если ключа ещё нет)
  ключ        путь к приватному ключу; по умолчанию ищем в ~/.ssh
  --key-only  только скопировать ключ, скрипт не запускать
  --reinstall удалить старый ключ хоста из known_hosts (после переустановки OS)
USAGE
  exit 0
}

# ------------------------------ аргументы -----------------------------
positional=()
for a in "$@"; do
  case "$a" in
    -h|--help) usage ;;
    --key-only) KEY_ONLY=1 ;;
    --reinstall) REINSTALL=1 ;;
    -*) die "Неизвестный флаг: $a" ;;
    *) positional+=("$a") ;;
  esac
done
[ "${#positional[@]}" -ge 1 ] || usage

TARGET="${positional[0]}"
[ "${#positional[@]}" -ge 2 ] && KEY_PATH="${positional[1]}"

# Гарантируем, что настройка идёт от root. Просто IP тоже принимаем.
case "$TARGET" in
  root@*) ;;
  *@*) die "Цель должна быть root@<ip> или просто <ip>, а не $TARGET" ;;
  *) TARGET="root@$TARGET" ;;
esac

command -v ssh >/dev/null 2>&1 || die "Не найден ssh (macOS: поставь OpenSSH через xcode-select --install)"

# --------------------------- поиск ключа ------------------------------
if [ -z "$KEY_PATH" ]; then
  for cand in id_ed25519 id_ecdsa id_rsa; do
    if [ -f "$HOME/.ssh/$cand" ] && [ -f "$HOME/.ssh/$cand.pub" ]; then
      KEY_PATH="$HOME/.ssh/$cand"
      break
    fi
  done
fi
[ -n "$KEY_PATH" ] || die "Не нашёл приватный ключ в ~/.ssh. Создай: ssh-keygen -t ed25519"
[ -f "$KEY_PATH" ] || die "Нет файла $KEY_PATH"
[ -f "$KEY_PATH.pub" ] || ssh-keygen -y -f "$KEY_PATH" > "$KEY_PATH.pub"

PUBKEY="$(cat "$KEY_PATH.pub")"
PUBKEY_B64="$(printf '%s' "$PUBKEY" | base64 | tr -d '\n')"
FINGERPRINT="$(ssh-keygen -lf "$KEY_PATH.pub" 2>/dev/null | awk '{print $2}')"

SSH_OPTS=(-o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

# --------------------------- 1. доступ --------------------------------
server_ip="${TARGET##*@}"

if [ "$REINSTALL" -eq 1 ]; then
  step "0/4  Удаление старого ключа хоста $server_ip из known_hosts"
  ssh-keygen -R "$server_ip" >/dev/null 2>&1 || true
  log "старый ключ хоста удалён (режим переустановки)"
fi

step "1/4  Копирование SSH-ключа на $TARGET"
info "ключ:   $KEY_PATH"
info "отпечаток: $FINGERPRINT"

if ssh "${SSH_OPTS[@]}" -o IdentitiesOnly=yes -i "$KEY_PATH" -o BatchMode=yes "$TARGET" true 2>/dev/null; then
  log "ключ уже на сервере, повторно не копирую"
else
  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id "${SSH_OPTS[@]}" -o IdentitiesOnly=yes -i "$KEY_PATH.pub" "$TARGET"
  else
    info "ssh-copy-id не найден, копирую через cat"
    ssh "${SSH_OPTS[@]}" -o IdentitiesOnly=yes -i "$KEY_PATH" "$TARGET" \
      'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys' < "$KEY_PATH.pub"
  fi
  ssh "${SSH_OPTS[@]}" -o IdentitiesOnly=yes -i "$KEY_PATH" -o BatchMode=yes "$TARGET" true \
    || die "Ключ скопирован, но вход по нему не работает — проверь ~/.ssh/authorized_keys"
  log "ключ установлен, вход без пароля работает"
fi

[ "$KEY_ONLY" -eq 1 ] && { log "--key-only: на этом всё"; exit 0; }

# --------------------------- 2. загрузка ------------------------------
step "2/4  Загрузка скрипта на сервер"
[ -f "$SETUP_SCRIPT" ] || die "Не найден $SETUP_SCRIPT"
# REMOTE_DIR — константа выше, раскрытие на клиенте безопасно.
# shellcheck disable=SC2029
tar -C "$SCRIPT_DIR" -czf - setup-vps.sh \
  | ssh "${SSH_OPTS[@]}" -o IdentitiesOnly=yes -i "$KEY_PATH" "$TARGET" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR' && tar -C '$REMOTE_DIR' -xzf - && chmod +x '$REMOTE_DIR/setup-vps.sh'"
log "скрипт залит в $REMOTE_DIR"

# --------------------------- 3. запуск --------------------------------
step "3/4  Запуск настройки от root"
# -tt гарантирует TTY даже если bootstrap запущен не из интерактивного терминала
ssh -tt "${SSH_OPTS[@]}" -o IdentitiesOnly=yes -i "$KEY_PATH" "$TARGET" "PUBKEY_B64='$PUBKEY_B64' bash '$REMOTE_DIR/setup-vps.sh'"

# --------------------------- 4. проверка ------------------------------
step "4/4  Проверка входа root по ключу"
if ssh "${SSH_OPTS[@]}" -o IdentitiesOnly=yes -i "$KEY_PATH" -o BatchMode=yes -o ConnectTimeout=15 \
     -o StrictHostKeyChecking=accept-new "root@$server_ip" \
     'echo OK: вход root по ключу работает' 2>/dev/null; then
  log "вход root по ключу работает"
  echo
  echo "  ssh root@$server_ip"
  echo "  cat /root/vps-setup-report.txt"
else
  warn "Вход root по ключу не удался — текущая сессия ещё жива, не закрывай её"
  info "проверь вручную: ssh -i $KEY_PATH root@$server_ip"
  info "на сервере: cat /root/.ssh/authorized_keys"
fi

echo
log "готово"
