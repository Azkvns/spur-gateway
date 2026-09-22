# Spur Gateway (RU)

**Spur Gateway** — opt-in локальный SOCKS5 / HTTP CONNECT шлюз в Docker на базе sing-box-extended. Прокси слушают только loopback:

- `127.0.0.1:1090` — SOCKS5
- `127.0.0.1:8128` — HTTP CONNECT

Системные маршруты хоста не меняются: вы сами выбираете, какие команды или профили браузера идут через шлюз.

## Быстрый старт

```bash
git clone https://github.com/Azkvns/spur-gateway.git
cd spur-gateway
make env
# укажите SPUR_SUB_URL в .env
export PATH="$PWD/bin:$PATH"
make up
spur curl -sI https://example.com
```

## Дальше

Полная документация на английском:

- [Home](../index.md)
- [Quick start](../quickstart.md)
- [CLI](../cli.md)
- [Configuration](../configuration.md)
- [Docker](../docker.md)
- [Operations](../operations.md)
