# server-setup

Скрипты для настройки VPS и установки 3x-ui-pro (mozaroc) с Hysteria2 (UDP/443), Cloudflare WARP и DNS Quad9 DoH. Работает только по IPv4.

Подробная инструкция, описание всех шагов и траблшутинг: [`3x-ui-pro-hysteria2/README.md`](3x-ui-pro-hysteria2/README.md).

## Структура

| Путь | Назначение |
|---|---|
| `vps-setup/bootstrap.sh` | Запускается на своей машине. Копирует SSH-ключ на сервер и запускает `setup-vps.sh`. |
| `vps-setup/setup-vps.sh` | Настройка сервера: пакеты, swap, sysctl, отключение IPv6, UFW, fail2ban, SSH только по ключу, лимиты логов. |
| `3x-ui-pro-hysteria2/install.sh` | Установка 3x-ui-pro, WARP с fallback, Hysteria2, единая подписка, Quad9 DoH, Clash-шаблон. |
| `3x-ui-pro-hysteria2/assets/clash/clash.yaml` | Шаблон Clash-подписки. |
| `3x-ui-pro-hysteria2/README.md` | Подробная инструкция. |

## Порядок работы

1. Направить A-записи обоих доменов на IP сервера.
2. На своей машине, из папки `vps-setup/`, настроить сервер:
   ```bash
   ./bootstrap.sh root@<ip> ~/.ssh/id_ed25519
   ```
3. Перезагрузить сервер:
   ```bash
   ssh root@<ip> reboot
   ```
4. На сервере, из папки `3x-ui-pro-hysteria2/`, установить панель:
   ```bash
   bash install.sh <panel-domain> <reality-domain> --warp
   ```

Перед шагом 4 IPv6 должен быть отключён, иначе установщик остановится с ошибкой.

## Плейсхолдеры

В документации используются плейсхолдеры `<ip>`, `<panel-domain>`, `<reality-domain>`, `panel.example1.domain.com`, `reality.example2.domain.com`. Реальные IP, домены и пароли в файлы не попадают.

## Благодарности

Этот проект — форк [3x-ui-pro](https://github.com/mozaroc/3x-ui-pro) от [mozaroc](https://github.com/mozaroc). Установку панели, REALITY и остальных протоколов выполняет его установщик `x-ui-latest.sh`. Сама панель основана на [3x-ui](https://github.com/MHSanaei/3x-ui) от [MHSanaei](https://github.com/MHSanaei). Скрипты этого репозитория добавляют к ним Hysteria2, Cloudflare WARP с fallback, DNS Quad9 DoH и первичную настройку сервера.
