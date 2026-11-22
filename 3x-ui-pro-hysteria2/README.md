# 3x-ui-pro + Hysteria2 + Quad9 DoH + WARP

Автоматическая настройка VPN-сервера: панель `mozaroc/3x-ui-pro`, Hysteria2 на UDP/443, единая подписка на все протоколы, DNS Quad9 (DoH) и опционально Cloudflare WARP с автоматическим переходом на прямой выход при падении WARP. Сервер работает в IPv4-only режиме.

---

## Системные требования

- **ОС:** чистый VPS на Ubuntu 24.04 или Debian 12
- **Домены:** 2 поддомена с A-записями на IP сервера
  - панель управления, например `panel.example1.domain.com`
  - REALITY, например `reality.example2.domain.com`
- **Права:** root и SSH-ключ
- **Ресурсы:** рекомендуется 1 vCPU и 1 GB RAM (точные минимумы не замерялись)
- **С Mac-компьютера:** `ssh`, `ssh-keygen` (есть по умолчанию)

---

## Структура репозитория

```
.
├── vps-setup/
│   ├── bootstrap.sh          # Копирует SSH-ключ на сервер и запускает setup-vps.sh (с Mac)
│   └── setup-vps.sh          # Первичная настройка и харденинг сервера
└── 3x-ui-pro-hysteria2/
    ├── install.sh            # Единый установщик панели, Hysteria2, DNS, WARP
    ├── assets/clash/clash.yaml  # Clash-шаблон подписки
    └── README.md
```

---

## Порядок установки

### Шаг 0. Fork и настройка ссылок

После fork замените `YOUR_USER/YOUR_REPO` в командах ниже на свой репозиторий.

### Шаг 1. Ключ SSH и первичная настройка (с Mac)

```bash
bash vps-setup/bootstrap.sh root@<ip-сервера>
```

Скрипт:
1. Копирует публичный ключ `~/.ssh/id_ed25519.pub` на сервер (пароль root понадобится один раз).
2. Загружает `setup-vps.sh` и запускает его.
3. Проверяет вход по ключу.

Если нужен другой ключ: `bash vps-setup/bootstrap.sh root@<ip> ~/.ssh/my_key`.

### Шаг 2. Что делает `setup-vps.sh`

Запускается автоматически из шага 1. Выполняет:

1. **Пакеты:** обновление системы, установка `ufw`, `fail2ban`, `chrony`, `unattended-upgrades` и других утилит.
2. **Swap:** 2 GB (если swap ещё нет).
3. **Параметры ядра:** защита от спуфинга, `ip_forward`, буферы для Xray/WARP.
4. **Отключение IPv6:**
   - `/etc/sysctl.d/99-disable-ipv6.conf` с `disable_ipv6 = 1`;
   - конфликтующие IPv6-строки в других sysctl-файлах комментируются;
   - `/etc/netplan/99-disable-ipv6.yaml`: `dhcp6: false`, `accept-ra: false` для основного интерфейса;
   - `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`: cloud-init не перезаписывает сеть;
   - UFW с `IPV6=no`.
5. **Ключ SSH:** проверяется наличие ключа в `/root/.ssh/authorized_keys`. Без ключа установка останавливается, парольный вход не отключается.
6. **SSH:** только ключи, пароль отключён, вход root по ключу.
7. **UFW:** по умолчанию закрыто входящее; открыты `22/tcp` (с ограничением частоты), `53, 80, 443, 4443, 8443/tcp` и `53, 443, 51820/udp`.
8. **Fail2ban:** защита только SSH (8 попыток за 15 минут, бан на 1 час с ростом).
9. **Логи:** лимиты journald, logrotate по размеру, watchdog с потолком 100 МБ.
10. **Docker (если есть):** `DOCKER-USER` не даёт обойти UFW.

**После шага 2 обязательно перезагрузите сервер:**

```bash
ssh root@<ip-сервера> reboot
```

Netplan и cloud-init применяются при загрузке. Проверка после перезагрузки:

```bash
ip -6 addr show scope global      # пусто
sysctl net.ipv6.conf.all.disable_ipv6   # = 1
```

### Шаг 3. Установка панели и VPN

На сервере, в папке репозитория или через curl:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/3x-ui-pro-hysteria2/install.sh) panel.example1.domain.com reality.example2.domain.com
```

Установщик спросит:

```
Ставим Cloudflare WARP (весь трафик клиентов через WARP)? [y/N]
```

- `y` — WARP устанавливается, весь трафик клиентов идёт через Cloudflare.
- `N` — WARP не ставится, трафик идёт напрямую.

Для неинтерактивного запуска используйте флаги:

```bash
bash install.sh panel.example1.domain.com reality.example2.domain.com --warp
bash install.sh panel.example1.domain.com reality.example2.domain.com --no-warp
```

Если репозиторий уже склонирован на сервер, можно запускать локальный файл:

```bash
cd 3x-ui-pro-hysteria2
bash install.sh panel.example1.domain.com reality.example2.domain.com
```

Переменные окружения:
- `SKIP_DNS_CHECK=1` — пропустить проверку, что оба домена указывают на IP сервера;
- `REPO_RAW=...` — базовый URL папки `3x-ui-pro-hysteria2` (нужен только для запуска через curl без локальных файлов).

### Что делает `install.sh`

1. **Предпроверки:** ОС, A-записи доменов совпадают с IP сервера, IPv6 отключён (иначе установка останавливается).
2. **Выбор WARP:** интерактивно или флагом `--warp` / `--no-warp`.
3. **mozaroc/3x-ui-pro:** панель, REALITY, VLESS WS, VLESS XHTTP, Trojan gRPC. Если 3x-ui уже установлен, этот шаг пропускается.
4. **WARP (только при выборе «да»):**
   - `wgcf` регистрирует бесплатный аккаунт и генерирует профиль WireGuard;
   - интерфейс `wgcf` поднимается с `Table = off`, поэтому маршрут по умолчанию и SSH не меняются;
   - endpoint IPv4 `162.159.192.1:2408`, `PersistentKeepalive = 25`;
   - policy routing: пакеты с меткой `fwmark 51820` идут через таблицу 51820 в `wgcf`;
   - healthcheck раз в минуту перезапускает WARP, если handshake старше 180 секунд.
5. **Hysteria2:** inbound на UDP/443. Порт TCP/443 при этом остаётся за nginx, конфликтов нет.
6. **Единый клиент:** один клиент с общим `subId` привязан ко всем inbound'ам, поэтому одна подписка содержит все протоколы.
7. **Xray (один запрос к API):**
   - DNS: `https://dns.quad9.net/dns-query` с `queryStrategy: UseIPv4`;
   - outbound `direct` (прямой выход);
   - при WARP: outbound `WARP` (через `wgcf`, метка 51820), `observatory` проверяет WARP каждые 30 секунд, balancer `warp-or-direct` выбирает WARP, а при его недоступности автоматически `direct`;
   - без WARP: весь трафик идёт в `direct`.
8. **Clash-шаблон:** Hysteria2-группа, клиентский DNS Quad9 через прокси, `ipv6: false`.
9. **Проверка:** панель отвечает 200, подписка содержит `hysteria2`, UDP/443 слушается, IPv6 отсутствует, выход через WARP (если включён).

---

## Что выводится в конце

```
============================================================
  3x-ui-pro + Hysteria2 установлен
============================================================
Панель   : https://panel.example1.domain.com/<base-path>/
Логин    : <username>
Пароль   : <password>

Подписка : https://panel.example1.domain.com/<sub-path>/<sub-id>
Hysteria2: hysteria2://...

WARP     : включён (IP: ...), при падении WARP трафик идёт напрямую
```

Все данные сохраняются в файлах с правами `600`:

| Файл | Содержимое |
|------|------------|
| `/root/3x-ui-pro-credentials.txt` | URL панели, логин, пароль |
| `/root/hysteria2-credentials.txt` | подписка, ссылка Hysteria2, параметры WARP и DNS |

---

## Подписка и клиенты

- **Clash / Mihomo:** подписка содержит все протоколы, группу `🚀 Hysteria2` и DNS Quad9.
- **v2rayN / Shadowrocket / другие:** base64-подписка содержит все протоколы. DNS в них не передаётся, его нужно настроить в приложении.

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
```

Если клиент показывает IP сервера вместо Cloudflare, это нормально при падении WARP: сработал fallback на прямой выход.

---

## Траблшутинг

**Вход по ключу не работает после setup-vps.sh.** Текущая SSH-сессия остаётся открытой. Проверьте `/root/.ssh/authorized_keys` и `sshd -T | grep -i passwordauth`.

**IPv6 остался после перезагрузки.** Проверьте `/etc/netplan/99-disable-ipv6.yaml` и `sysctl net.ipv6.conf.all.disable_ipv6`. Если в конфиге есть `disable_ipv6 = 0`, поправьте файл и перезагрузите сервер.

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

**Hysteria2 не работает.** Убедитесь, что `ufw status` содержит `443/udp`, и что клиент использует домен панели с портом 443.

---

## Безопасность

- Панель доступна только по HTTPS через nginx.
- SSH: только ключи, пароль отключён, вход root только по ключу.
- UFW закрывает всё входящее, кроме перечисленных портов.
- Fail2ban защищает SSH.
- Docker-контейнеры не обходят UFW благодаря `DOCKER-USER`.
- Логин и пароль панели, ссылки подписки хранятся в `/root` с правами `600`.

---

## Обновления

Стандартное обновление 3x-ui через меню `x-ui` не отменяет Hysteria2: inbound'ы хранятся в `/etc/x-ui/x-ui.db`. Повторный запуск `install.sh` на уже настроенном сервере не дублирует Hysteria2 (берёт параметры существующего inbound).
