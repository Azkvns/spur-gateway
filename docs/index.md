# Spur Gateway

**Spur Gateway** is an opt-in local SOCKS5 and HTTP CONNECT gateway. It runs in Docker with [sing-box-extended](https://github.com/shtorm-7/sing-box-extended) and exposes loopback proxies only:

- `127.0.0.1:1090` — SOCKS5
- `127.0.0.1:8128` — HTTP CONNECT

Host routing tables stay untouched. You choose which commands or browser profiles use the gateway.

## Why

Use a per-command or per-profile proxy without changing system routes. The watchdog keeps a healthy outbound selected, can soft-rotate on a timer, and can refresh the subscription when probes stay unhealthy.

## Docs

- [Quick start](quickstart.md)
- [CLI](cli.md)
- [Configuration](configuration.md)
- [Docker / GHCR](docker.md)
- [Operations](operations.md)
- [Русский обзор](ru/index.md)

## License

MIT. See [NOTICE](https://github.com/Azkvns/spur-gateway/blob/main/NOTICE) for third-party components (sing-box-extended is GPL-3.0+).
