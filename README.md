# Spur Gateway

[![test](https://github.com/Azkvns/spur-gateway/actions/workflows/test.yml/badge.svg)](https://github.com/Azkvns/spur-gateway/actions/workflows/test.yml)
[![Maintainability](https://qlty.sh/gh/Azkvns/projects/spur-gateway/maintainability.svg)](https://qlty.sh/gh/Azkvns/projects/spur-gateway/metrics/code)
[![license](https://img.shields.io/github/license/Azkvns/spur-gateway)](LICENSE)
[![GHCR](https://img.shields.io/badge/GHCR-spur--gateway-blue)](https://github.com/Azkvns/spur-gateway/pkgs/container/spur-gateway)
[![docs](https://img.shields.io/badge/docs-GitHub%20Pages-brightgreen)](https://azkvns.github.io/spur-gateway/)

Opt-in local **SOCKS5** and **HTTP CONNECT** gateway. Runs in Docker on [sing-box-extended](https://github.com/shtorm-7/sing-box-extended) and binds proxies to loopback only:

| Protocol | Address |
|----------|---------|
| SOCKS5 | `127.0.0.1:1090` |
| HTTP CONNECT | `127.0.0.1:8128` |

Host routing tables stay unchanged. Wrap individual commands with `spur`, or point a browser profile at the proxy.

## Features

- Loopback-only SOCKS5 and HTTP CONNECT (no system-wide VPN / TUN)
- Per-command wrapper (`spur`) and optional browser proxy profile
- Health probes and soft rotate via in-container watchdog
- Live VLESS subscription mode, or mock direct-only mode for local smoke tests
- Multi-arch images on GHCR (`:vX.Y.Z`, `:latest`)

## Requirements

- Docker with Compose v2
- For live mode: a VLESS subscription URL in `.env` as `SPUR_SUB_URL` (never commit secrets)

## Install from source

```bash
git clone https://github.com/Azkvns/spur-gateway.git
cd spur-gateway
make env                 # creates .env — set SPUR_SUB_URL
export PATH="$PWD/bin:$PATH"
make up                  # build image + start stack
spur curl -sI https://example.com
```

Mock stack (no subscription): `make up-mock`.

Stop: `make down`.

## Install with a prebuilt Docker image

Pull a release image from GHCR (no local build):

```bash
docker pull ghcr.io/azkvns/spur-gateway:latest
```

Run the container (loopback publish + subscription env):

```bash
docker run -d --name spur-gateway --restart unless-stopped \
  -e SPUR_SUB_URL='your-subscription-url' \
  -p 127.0.0.1:1090:1090 \
  -p 127.0.0.1:8128:8128 \
  ghcr.io/azkvns/spur-gateway:latest
```

- Mock without a subscription: add `-e SPUR_MOCK=1` and omit `SPUR_SUB_URL`.
- Prefer a version tag in production: `ghcr.io/azkvns/spur-gateway:vX.Y.Z`.
- The container alone exposes the proxies. The `spur` / `spur-gw` CLIs still come from this repo (`export PATH="$PWD/bin:$PATH"` after clone), or point clients at `127.0.0.1:1090` / `8128` directly.

## Use the proxy

```bash
spur curl -sI https://example.com
spur git clone git@github.com:example/repo.git
```

Chrome:

```text
--proxy-server=socks5://127.0.0.1:1090
```

## Make targets

| Target | Purpose |
|--------|---------|
| `make env` | Create `.env` from `.env.example` if missing |
| `make up` | Build and start live gateway |
| `make up-mock` | Build and start mock gateway |
| `make down` | Stop the stack |
| `make status` | Compose / health status |
| `make logs` | Tail gateway logs |

## Documentation

- [English docs](https://azkvns.github.io/spur-gateway/)
- [Русский обзор](https://azkvns.github.io/spur-gateway/ru/)
- Source: [`docs/`](docs/)

## CI and releases

- Every PR runs `test` (`bash tests/run.sh`).
- Same-repo PRs can squash auto-merge after green checks; **fork PRs are never auto-merged**.
- Each merge to `main` tags a semver release and pushes multi-arch images to GHCR (`:vX.Y.Z`, `:latest`). Use `[skip release]` in the subject to skip.

## License

MIT. Third-party notices: [NOTICE](NOTICE) (sing-box-extended is GPL-3.0+).
