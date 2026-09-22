# Configuration

Copy `.env.example` to `.env` (`make env`) and set values as needed.

| Variable | Default | Purpose |
|----------|---------|---------|
| `SPUR_SUB_URL` | _(empty)_ | Subscription URL (secret; not in git) |
| `SPUR_MOCK` | `0` | `1` = mock direct config, no subscription |
| `SOCKS_PORT` | `1090` | SOCKS5 listen port |
| `HTTP_PORT` | `8128` | HTTP CONNECT listen port |
| `SPUR_HEALTH_INTERVAL` | `15` | Watchdog probe interval (seconds) |
| `SPUR_HEALTH_TIMEOUT` | `8` | Per-probe curl timeout (seconds) |
| `SPUR_PROBE_PRIMARY` | `https://www.google.com` | Primary health URL |
| `SPUR_PROBE_SECONDARY` | `https://example.com` | Secondary health URL(s), CSV |
| `SPUR_PROBE_FAILS` | `3` | Failures before unhealthy (hysteresis) |
| `SPUR_ROTATE_INTERVAL` | `1800` | Soft rotate interval (seconds) |
| `SPUR_UPGRADE_MIN_IMPROVE_MS` | `80` | Min absolute latency gain for rotate |
| `SPUR_UPGRADE_MIN_IMPROVE_RATIO` | `0.3` | Min relative latency gain for rotate |
| `SPUR_RECONNECT_BACKOFF_MAX` | `60` | Max reconnect backoff (seconds) |
| `SPUR_SUB_REFRESH_INTERVAL` | `86400` | Periodic subscription refresh |
| `SPUR_SUB_REFRESH_FAIL_COOLDOWN` | `900` | Cooldown after forced refresh |

Override the env file path with `SPUR_GW_ENV_FILE`.
