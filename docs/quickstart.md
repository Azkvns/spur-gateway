# Quick start

## Requirements

- Docker and Docker Compose
- A VLESS subscription URL (kept in `.env`, never committed)

## Install

```bash
git clone https://github.com/Azkvns/spur-gateway.git
cd spur-gateway
make env
# edit .env and set SPUR_SUB_URL
export PATH="$PWD/bin:$PATH"
```

## Run

```bash
make up          # live subscription
# or
make up-mock     # mock direct-only config (no subscription)
spur-gw status
```

## Use the proxy

```bash
spur curl -sI https://example.com
spur git clone git@github.com:example/repo.git
```

Chrome example:

```text
--proxy-server=socks5://127.0.0.1:1090
```

## Stop

```bash
make down
```
