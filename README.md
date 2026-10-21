# 3x-ui-pro + Hysteria2

Автоматический установщик `mozaroc/3x-ui-pro` с добавлением **Hysteria2** на UDP/443 и единой подпиской на все протоколы.

## Что делает

1. Устанавливает панель `mozaroc/3x-ui-pro` (REALITY, VLESS WS, VLESS XHTTP, Trojan gRPC).
2. Создаёт Hysteria2 inbound на **UDP/443** (параллельно с nginx TCP/443).
3. Создаёт одного клиента и привязывает его ко **всем inbound'ам** — одна подписка включает все протоколы.
4. Заменяет Clash-шаблон на Hysteria2-совместимый, с отдельной группой `🚀 Hysteria2`.

## Требования

- Чистый VPS на Ubuntu 24.04 или Debian 12
- Два домена/поддомена (как требует оригинальный `mozaroc/3x-ui-pro`)
- root-доступ

## Быстрый старт

1. Сделайте fork этого репозитория.
2. В `install.sh` замените `YOUR_USER/YOUR_REPO` на свой GitHub:
   ```bash
   REPO_RAW="https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main"
   ```
3. Запустите на VPS, передав два домена:
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/install.sh) kone.vkvideo.download nokia.vkvideo.download
   ```

## Структура

```
.
├── install.sh              # Основной установщик
├── add-hysteria2.sh        # Создание Hysteria2 и единого клиента
├── assets/clash/clash.yaml # Доработанный Clash-шаблон
└── README.md
```

## После установки

Все данные сохраняются в:
- `/root/3x-ui-pro-credentials.txt` — логин/пароль панели
- `/root/hysteria2-credentials.txt` — ссылка Hysteria2 и URL подписки

В Clash/Mihomo подписка автоматически включает:
- VLESS+REALITY
- VLESS+WebSocket
- VLESS+XHTTP
- Trojan+gRPC
- **Hysteria2**

Группа `🚀 Hysteria2` позволяет быстро переключиться только на Hysteria2.

## Как это работает

- nginx слушает **TCP/443** и маршрутизирует REALITY/WS/XHTTP/Trojan.
- Xray слушает **UDP/443** для Hysteria2 (QUIC).
- TCP и UDP на одном порту не конфликтуют.

## Безопасность

- Панель 3x-ui остаётся за nginx с TLS.
- Реальные логин/пароль панели извлекаются из вывода установщика и сохраняются только в `/root/3x-ui-pro-credentials.txt` (права 600).
- Hysteria2 использует TLS с теми же сертификатами Let's Encrypt, что и панель.

## Обновления

Этот форк не отменяет стандартное обновление 3x-ui через меню `x-ui`. После обновления панели Hysteria2 inbound сохранится, так как он хранится в базе панели.
