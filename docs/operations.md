# Operations

## Health

The container writes `/run/spur-gw-health` (`state=`, `reason=`, `server=`, `updated=`).

Compose healthcheck requires `state=ok` and SOCKS port `1090` listening.

`spur-gw status` prints `compose=` and `health=`.

## Watchdog

In live mode the watchdog:

1. Probes primary and secondary URLs through the SOCKS proxy
2. Applies hysteresis (`SPUR_PROBE_FAILS`)
3. Failovers via the Clash API selector when unhealthy. A live sing-box process stays up if the new member still fails probes; the next tick tries another member. Connections whose chain contains the previous outbound are closed so clients reconnect. sing-box is restarted only when the process or the listen ports are already down.
4. Soft-rotates toward a faster member on a timer, and only when Clash reports zero open connections. A busy tunnel keeps the current member and does not consume the rotate interval.
5. Refreshes the subscription on interval or after sustained failures. sing-box is reloaded when the running config is stale: the loaded outbound identity differs from the on-disk file, or the selected tag has just left the pool. A tag that is already absent from the pool is left alone on later refreshes. When the current tag cannot be read, reload happens only if the on-disk outbounds differ from the last loaded config.

Mock mode only supervises the process and writes healthy status.

## Third-party licenses

See repository `NOTICE`. Runtime includes GPL-3.0+ sing-box-extended and Debian packages in the image.
