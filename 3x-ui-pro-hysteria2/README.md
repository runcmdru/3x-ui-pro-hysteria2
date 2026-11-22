# 3x-ui-pro + Hysteria2 + Quad9 DoH + WARP

Установщик VPN-сервера на базе панели [mozaroc/3x-ui-pro](https://github.com/mozaroc/3x-ui-pro) с Hysteria2 на UDP/443, единой подпиской на все протоколы, DNS Quad9 (DoH) и опциональным Cloudflare WARP. Если WARP падает, трафик автоматически уходит напрямую. Сервер работает только по IPv4.

Перед установкой сначала настраивается сервер скриптом `vps-setup/setup-vps.sh` (см. корневой `README.md`).

---

## Требования

- **ОС:** чистый VPS на Ubuntu 24.04 или Debian 12.
- **Домены:** два поддомена с A-записями на IP сервера:
  - панель, например `panel.example1.domain.com`;
  - REALITY, например `reality.example2.domain.com`.
- **Права:** root и SSH-ключ.
- **Ресурсы:** рекомендуется 1 vCPU и 1 GB RAM (точные минимумы не замерялись).
- **С Mac:** `ssh`, `ssh-keygen` (есть по умолчанию).

---

## Структура

```
3x-ui-pro-hysteria2/
├── install.sh                    # Установщик: панель, WARP, Hysteria2, DNS, подписка
├── assets/clash/clash.yaml       # Шаблон Clash-подписки
└── README.md
```

Настройка сервера лежит в соседней папке `vps-setup/`:

```
vps-setup/
├── bootstrap.sh                  # Запускается на Mac: копирует ключ и запускает setup-vps.sh
└── setup-vps.sh                  # Первичная настройка и харденинг сервера
```

---

## Порядок установки

### Шаг 1. Клонирование репозитория (на Mac)

```bash
git clone https://github.com/runcmdru/3x-ui-pro-hysteria2.git
```

Репозиторий содержит папки `vps-setup/` и `3x-ui-pro-hysteria2/`. Команды ниже выполняются из корня репозитория `3x-ui-pro-hysteria2`, где лежат обе папки.

### Шаг 2. Ключ SSH и первичная настройка (на Mac)

```bash
cd vps-setup
./bootstrap.sh root@<ip-сервера> [путь-к-приватному-ключу] [--key-only | --reinstall]
```

По умолчанию используется `~/.ssh/id_ed25519`. Пример:

```bash
./bootstrap.sh root@<ip>                          # ключ ~/.ssh/id_ed25519
./bootstrap.sh root@<ip> ~/.ssh/my_key            # другой ключ
./bootstrap.sh root@<ip> ~/.ssh/id_ed25519 --key-only    # только скопировать ключ
./bootstrap.sh root@<ip> ~/.ssh/id_ed25519 --reinstall   # после переустановки ОС
```

Скрипт:
1. Копирует публичный ключ на сервер. Пароль root понадобится один раз. Если ключ уже есть на сервере, повторно не копирует.
2. Загружает `setup-vps.sh` в `/root/vps-setup/` и запускает его, передавая ключ в переменной `PUBKEY_B64`.
3. Проверяет вход по ключу.

**Перед запуском проверьте, что на сервере нет активного `unattended-upgrades`.** Иначе `setup-vps.sh` остановится на блокировке dpkg. Подождите, пока он завершится, и запустите снова.

### Шаг 3. Что делает `setup-vps.sh`

Запускается из шага 2 и выполняет:

1. **Пакеты:** обновление системы, установка `ufw`, `fail2ban`, `chrony`, `unattended-upgrades`, `jq`, `dnsutils` и других утилит.
2. **Swap:** по умолчанию 2 GB, если swap ещё нет.
3. **Параметры ядра:** защита от спуфинга, `ip_forward`, буферы для Xray и WARP.
4. **Отключение IPv6:**
   - статические IPv6-адреса, маршруты и DNS, которые провайдер прописал в netplan (например, в `/etc/netplan/50-cloud-init.yaml`), удаляются, перед этим делается резервная копия;
   - `/etc/netplan/99-disable-ipv6.yaml` с `dhcp6: false`, `accept-ra: false` и `link-local: []`;
   - `/etc/sysctl.d/99-disable-ipv6.conf` с `disable_ipv6 = 1` для всех интерфейсов;
   - конфликтующие IPv6-строки в других sysctl-файлах комментируются;
   - `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`, чтобы cloud-init не перезаписывал сеть;
   - служба `ipv6-disable.service` выставляет `disable_ipv6 = 1` при каждой загрузке;
   - в UFW задано `IPV6=no`.
5. **Ключ SSH:** проверяется наличие ключа в `/root/.ssh/authorized_keys`. Без ключа установка останавливается, парольный вход не отключается.
6. **SSH:** вход только по ключу, пароль отключён, root только по ключу.
7. **UFW:** по умолчанию закрыто входящее. Открыты `22/tcp` (с ограничением частоты), `53, 80, 443, 4443, 8443/tcp` и `53, 443, 51820/udp`.
8. **Fail2ban:** защита только SSH: 8 попыток за 15 минут, бан на 1 час с ростом до 1 дня.
9. **Логи:** лимит journald 60 МБ, logrotate по размеру, watchdog с потолком 100 МБ.
10. **Docker (если установлен):** правила в `DOCKER-USER`, чтобы контейнеры не обходили UFW.

Переменные окружения для `setup-vps.sh`:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `ADMIN_IP` | IP из `SSH_CONNECTION` | IP, который fail2ban никогда не банит. Если не определён, будет предупреждение. |
| `SWAP_SIZE` | `2G` | Размер swap-файла. |
| `TZ_OVERRIDE` | не меняется | Часовой пояс, например `Europe/Moscow`. |
| `SSH_PORT` | `22` | Порт SSH. |

Пример: `ADMIN_IP=203.0.113.10 TZ_OVERRIDE=Europe/Moscow ./setup-vps.sh` на сервере.

Отчёт о результатах: `/root/vps-setup-report.txt`. Резервные копии изменённых файлов: `/root/vps-setup-backup-<дата>/`.

**После шага 3 обязательно перезагрузите сервер:**

```bash
ssh root@<ip-сервера> reboot
```

Netplan и cloud-init применяются при загрузке. Проверка после перезагрузки:

```bash
ip -6 addr show scope global                 # пусто
for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do echo "$f = $(cat $f)"; done   # все = 1
systemctl is-active ipv6-disable             # active
```

### Шаг 4. Установка панели и VPN

На сервере, в папке с репозиторием:

```bash
cd 3x-ui-pro-hysteria2
bash install.sh panel.example1.domain.com reality.example2.domain.com
```

Установщик спросит:

```
Ставим Cloudflare WARP (весь трафик клиентов через WARP)? [y/N]
```

- `y`: WARP ставится, весь трафик клиентов идёт через Cloudflare.
- `N`: WARP не ставится, трафик идёт напрямую.

Для неинтерактивного запуска используйте флаги:

```bash
bash install.sh panel.example1.domain.com reality.example2.domain.com --warp
bash install.sh panel.example1.domain.com reality.example2.domain.com --no-warp
```

Запуск без склонированного репозитория (через `curl`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/runcmdru/3x-ui-pro-hysteria2/main/3x-ui-pro-hysteria2/install.sh) panel.example1.domain.com reality.example2.domain.com --warp
```

Переменные окружения:

| Переменная | Назначение |
|---|---|
| `SKIP_DNS_CHECK=1` | Пропустить проверку, что оба домена указывают на IP сервера. |
| `REPO_RAW=...` | Базовый URL папки `3x-ui-pro-hysteria2`. По умолчанию указывает на этот репозиторий. Нужен, если вы форкнули репозиторий. |

---

## Что делает `install.sh`

1. **Предпроверки:**
   - ОС;
   - A-записи обоих доменов совпадают с IP сервера;
   - IPv6 отключён. Если нет, установка останавливается с подсказкой запустить `setup-vps.sh` и перезагрузить сервер.
2. **Выбор WARP:** интерактивно или флагом `--warp` / `--no-warp`.
3. **mozaroc/3x-ui-pro:** панель, REALITY, VLESS WS, VLESS XHTTP, Trojan gRPC. Также ставятся заглушка сайта и сетевая диагностика из установщика mozaroc. Если 3x-ui уже установлен, этот шаг пропускается.
4. **WARP:**
   - `wgcf` регистрирует бесплатный аккаунт и создаёт профиль WireGuard;
   - интерфейс `wgcf` поднимается с `Table = off`, поэтому маршрут по умолчанию и SSH не меняются;
   - endpoint `162.159.192.1:2408`, `PersistentKeepalive = 25`;
   - policy routing: пакеты с меткой `fwmark 51820` идут через таблицу 51820 в `wgcf`;
   - healthcheck раз в минуту перезапускает WARP, если handshake старше 180 секунд.
   - При повторном запуске с `--no-warp` сервисы WARP останавливаются, а правила маршрутизации удаляются.
5. **Hysteria2:** inbound на UDP/443. TCP/443 остаётся за nginx, конфликтов нет. Если inbound Hysteria2 уже есть, его параметры переиспользуются, новый не создаётся.
6. **Единый клиент:** один клиент с общим `subId` привязан ко всем inbound'ам. Поэтому одна подписка содержит все протоколы.
7. **Xray (один запрос к API панели):**
   - DNS: `https://dns.quad9.net/dns-query`, `queryStrategy: UseIPv4`. Домен `dns.quad9.net` закреплён за `9.9.9.9` через `hosts`, иначе Xray не может открыть DoH-сервер и пишет ошибку `tries to resolve itself`;
   - outbound `direct` (прямой выход);
   - при WARP: outbound `WARP` через `wgcf`, `observatory` проверяет WARP каждые 30 секунд, balancer `warp-or-direct` выбирает WARP, а при его недоступности автоматически `direct`;
   - без WARP весь трафик идёт в `direct`.
8. **Clash-шаблон:** копируется в `/var/www/subpage/clash.yaml.tpl`. Содержит группу `🚀 Hysteria2`, клиентский DNS Quad9 через прокси и `ipv6: false`.
9. **Хук продления сертификата:** `/etc/letsencrypt/renewal-hooks/deploy/hysteria-cert.sh` перезапускает Hysteria2 после продления сертификата.
10. **Проверка:** панель отвечает 200, подписка содержит `hysteria2`, UDP/443 слушается, IPv6 отсутствует, выход через WARP (если включён).

---

## Что выводится в конце

```
============================================================
  3x-ui-pro + Hysteria2 установлен
============================================================
Логин    : <username>
Пароль   : <password>
Панель   : https://panel.example1.domain.com/<base-path>/
Подписка : https://panel.example1.domain.com/<sub-path>/<sub-id>
WARP     : включён (IP: ...), при падении WARP трафик идёт напрямую
Файлы    : /root/3x-ui-pro-credentials.txt, /root/hysteria2-credentials.txt
```

Ссылка Hysteria2 и параметры obfs выводятся в файле `/root/hysteria2-credentials.txt`.

Данные сохраняются с правами `600`:

| Файл | Содержимое |
|---|---|
| `/root/3x-ui-pro-credentials.txt` | URL панели, логин, пароль |
| `/root/hysteria2-credentials.txt` | подписка, ссылка Hysteria2, параметры obfs, WARP и DNS |

Прочие файлы, которые создаёт установка:

| Путь | Назначение |
|---|---|
| `/etc/x-ui/x-ui.db` | база панели, в ней inbound'ы и клиенты |
| `/etc/wireguard/wgcf.conf` | профиль WARP |
| `/root/wgcf-account.toml`, `/root/wgcf-profile.conf` | аккаунт и профиль wgcf |
| `/etc/warp/warp-route.sh`, `/etc/warp/warp-healthcheck.sh` | скрипты маршрутизации и healthcheck |
| `/etc/systemd/system/warp-route.service`, `warp-healthcheck.{service,timer}` | службы WARP |
| `/etc/systemd/system/x-ui.service.d/warp.conf` | `x-ui` стартует после WARP |
| `/var/www/subpage/clash.yaml.tpl` | Clash-шаблон подписки |

---

## Подписка и клиенты

- **Clash / Mihomo:** подписка содержит все протоколы, группу `🚀 Hysteria2` и DNS Quad9.
- **v2rayN / Shadowrocket и другие:** base64-подписка содержит все протоколы. DNS в них не передаётся, его нужно настроить в приложении.

---

## Проверка после установки

```bash
# Выход через WARP (если установлен)
curl --interface wgcf https://ipinfo.io/ip

# Выход сервера напрямую
curl -4 https://ipinfo.io/ip

# Состояние сервисов
systemctl status x-ui wg-quick@wgcf warp-route.service warp-healthcheck.timer

# UDP/443 слушается
ss -ulnp 'sport = :443'

# Ошибок DNS в логах Xray быть не должно
journalctl -u x-ui --no-pager | grep "resolve itself"
```

Если клиент показывает IP сервера вместо Cloudflare, это нормально при падении WARP: сработал fallback на прямой выход.

---

## Траблшутинг

**`setup-vps.sh` останавливается на `Could not get lock /var/lib/dpkg/lock-frontend`.** Это `unattended-upgrades` держит блокировку. Дождитесь его завершения или остановите: `systemctl stop unattended-upgrades`, затем запустите `setup-vps.sh` снова.

**Вход по ключу не работает после `setup-vps.sh`.** Текущая SSH-сессия остаётся открытой. Проверьте `/root/.ssh/authorized_keys` и `sshd -T | grep -i passwordauth`.

**IPv6 остался после перезагрузки.**
- Проверьте, нет ли в `/etc/netplan/*.yaml` адресов с `:` (`grep -n ':' /etc/netplan/*.yaml`). Такие строки относятся к IPv6, их нужно удалить и выполнить `netplan generate`.
- Проверьте `sysctl net.ipv6.conf.all.disable_ipv6` и `systemctl status ipv6-disable`.
- Для `eth0` значение `disable_ipv6` должно быть `1`. Если нет, перезагрузите сервер.

**`install.sh` пишет `IPv6 на сервере не отключён`.** Запустите `setup-vps.sh`, перезагрузите сервер и повторите установку.

**`install.sh` пишет `A-запись ... указывает на ...`.** Домен ещё не указывает на IP сервера или DNS не обновился. Подождите или запустите с `SKIP_DNS_CHECK=1`.

**Xray пишет `DOH//dns.quad9.net tries to resolve itself`.** Не закреплён `dns.quad9.net`. Повторный запуск `install.sh` добавит закрепление в `dns.hosts`. Проверка: `jq .dns /usr/local/x-ui/bin/config.json`.

**WARP не поднимается.**
```bash
systemctl status wg-quick@wgcf
journalctl -u wg-quick@wgcf -n 50
wg show wgcf
```

**Панель недоступна.**
```bash
systemctl status x-ui nginx
```

**Подписка возвращает 404.** Проверьте, что `subId` из подписки есть в базе: `sqlite3 /etc/x-ui/x-ui.db "SELECT email, sub_id FROM clients;"`. Если такого `subId` нет, в панели создайте клиента, привяжите его ко всем inbound'ам и возьмите новую ссылку подписки.

**Hysteria2 не работает.** Убедитесь, что `ufw status` содержит `443/udp`, и что клиент использует домен панели с портом 443.

---

## Безопасность

- Панель доступна только по HTTPS через nginx.
- SSH: только ключи, пароль отключён, root только по ключу.
- UFW закрывает всё входящее, кроме перечисленных портов.
- Fail2ban защищает SSH.
- Если установлен Docker, его контейнеры не обходят UFW благодаря `DOCKER-USER`.
- Логин, пароль панели и ссылки подписки хранятся в `/root` с правами `600`.
- Пароль root и любые пароли, переданные в чате, стоит сменить.

---

## Обновления

Стандартное обновление 3x-ui через меню `x-ui` не отменяет Hysteria2: inbound'ы хранятся в `/etc/x-ui/x-ui.db`. Повторный запуск `install.sh` на уже настроенном сервере не дублирует Hysteria2: берутся параметры существующего inbound.
