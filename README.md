# Spur Gateway

[![test](https://github.com/Azkvns/spur-gateway/actions/workflows/test.yml/badge.svg)](https://github.com/Azkvns/spur-gateway/actions/workflows/test.yml)
[![Maintainability](https://qlty.sh/gh/Azkvns/projects/spur-gateway/maintainability.svg)](https://qlty.sh/gh/Azkvns/projects/spur-gateway/metrics/code)
[![license](https://img.shields.io/github/license/Azkvns/spur-gateway)](LICENSE)
[![GHCR](https://img.shields.io/badge/GHCR-spur--gateway-blue)](https://github.com/Azkvns/spur-gateway/pkgs/container/spur-gateway)
[![docs](https://img.shields.io/badge/docs-GitHub%20Pages-brightgreen)](https://azkvns.github.io/spur-gateway/)

Opt-in local **SOCKS5** and **HTTP CONNECT** gateway on Docker + sing-box-extended.

Loopback only: `127.0.0.1:1090` (SOCKS5) · `127.0.0.1:8128` (HTTP CONNECT).

Host routes stay unchanged. Wrap individual commands with `spur`, or point a browser profile at the proxy.

## Quick start

```bash
git clone https://github.com/Azkvns/spur-gateway.git
cd spur-gateway
make env                 # creates .env — set SPUR_SUB_URL
export PATH="$PWD/bin:$PATH"
make up
spur curl -sI https://example.com
```

Or pull a released image: `ghcr.io/azkvns/spur-gateway:latest`.

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
