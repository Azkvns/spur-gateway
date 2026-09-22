# CLI

## `spur-gw`

```bash
spur-gw up|down|status
```

Loads `.env` (or `SPUR_GW_ENV_FILE`), requires `SPUR_SUB_URL` unless `SPUR_MOCK=1`, and drives Docker Compose.

## `spur`

Wraps a command with local proxy environment variables:

- `ALL_PROXY=socks5h://127.0.0.1:1090`
- `HTTP_PROXY` / `HTTPS_PROXY=http://127.0.0.1:8128`
- `NO_PROXY=localhost,127.0.0.1`

For `git`, `ssh`, `scp`, and `rsync`, sets `GIT_SSH_COMMAND` / `SSH_PROXY_COMMAND` via `nc` SOCKS when available.

`SPUR_SUB_URL` is never exported to the child process.

If the SOCKS port is closed, `spur` exits with `spur-gw up first`.
