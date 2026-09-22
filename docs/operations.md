# Operations

## Health

The container writes `/run/spur-gw-health` (`state=`, `reason=`, `server=`, `updated=`).

Compose healthcheck requires `state=ok` and SOCKS port `1090` listening.

`spur-gw status` prints `compose=` and `health=`.

## Watchdog

In live mode the watchdog:

1. Probes primary and secondary URLs through the SOCKS proxy
2. Applies hysteresis (`SPUR_PROBE_FAILS`)
3. Failovers via Clash API selector when unhealthy
4. Soft-rotates toward a faster member on a timer
5. Refreshes the subscription on interval or after sustained failures

Mock mode only supervises the process and writes healthy status.

## Third-party licenses

See repository `NOTICE`. Runtime includes GPL-3.0+ sing-box-extended and Debian packages in the image.
