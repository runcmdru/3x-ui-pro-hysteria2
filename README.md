# server-setup

Скрипты для настройки VPS и установки 3x-ui-pro (mozaroc) с Hysteria2 (UDP/443), Cloudflare WARP и DNS Quad9 DoH. Работает только по IPv4.

## Структура

| Путь | Назначение |
|---|---|
| `vps-setup/bootstrap.sh` | Запускается на своей машине. Копирует SSH-ключ на сервер и запускает настройку. |
| `vps-setup/setup-vps.sh` | Настройка сервера: пакеты, swap, sysctl, отключение IPv6, UFW, fail2ban, SSH только по ключу, лимиты логов. |
| `3x-ui-pro-hysteria2/install.sh` | Установка 3x-ui-pro, WARP, Hysteria2, единая подписка, Quad9 DoH, Clash-шаблон. |
| `3x-ui-pro-hysteria2/assets/clash/clash.yaml` | Шаблон Clash-подписки. |

## Порядок работы

1. Направить A-записи доменов на IP сервера.
2. Настроить сервер:
   ```bash
   cd vps-setup
   ./bootstrap.sh root@<ip> ~/.ssh/id_ed25519
   ```
3. Перезагрузить сервер и установить панель:
   ```bash
   cd 3x-ui-pro-hysteria2
   bash install.sh <panel-domain> <reality-domain> --warp
   ```

Подробности, файлы с данными доступа и troubleshooting — в `3x-ui-pro-hysteria2/README.md`.

## Плейсхолдеры

В репозитории используются плейсхолдеры `<ip>`, `example1.domain.com`, `example2.domain.com`. Реальные IP, домены и пароли в файлы не попадают.
