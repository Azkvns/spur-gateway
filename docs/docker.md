# Docker and GHCR

## Compose

Service name: `gateway`. Container name: `spur-gateway`.

Published ports (loopback only):

- `127.0.0.1:1090:1090`
- `127.0.0.1:8128:8128`

No `NET_ADMIN` and no TUN device.

Image builds sing-box-extended `1.13.14-extended-2.5.0` from `shtorm-7`.

## Prebuilt images

```bash
docker pull ghcr.io/azkvns/spur-gateway:latest
```

Tags published on each release: `:vX.Y.Z`, `:latest`, `:sha-<short>`.

## Make targets

`make build`, `make up`, `make up-mock`, `make down`, `make status`, `make logs`, `make smoke-mock`.
