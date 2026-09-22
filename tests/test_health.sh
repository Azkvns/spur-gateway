#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/helpers.sh
. "$ROOT/tests/helpers.sh"

HEALTH="$ROOT/docker/health.sh"
if [ ! -f "$HEALTH" ]; then
  echo "FAIL: docker/health.sh not found" >&2
  exit 1
fi

# shellcheck source=docker/health.sh
. "$HEALTH"

FAKEBIN="$(mktemp -d)"
CURL_LOG="$(mktemp)"
export CURL_LOG
trap 'rm -rf "$FAKEBIN" "$CURL_LOG"' EXIT

cat > "$FAKEBIN/curl" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
exit 0
EOF
chmod +x "$FAKEBIN/curl"

export SPUR_PROBE_PRIMARY="https://www.google.com"
export SPUR_PROBE_SECONDARY="https://example.com,https://www.wikipedia.org"
export SPUR_HEALTH_TIMEOUT=8
export SPUR_PROBE_FAILS=3
export SOCKS_PORT=1090
export HTTP_PORT=8128

# --- probe_fetch talks through SOCKS, never the raw network ---
: > "$CURL_LOG"
SOCKS_PORT=2090 SPUR_HEALTH_TIMEOUT=5 PATH="$FAKEBIN:$PATH" \
  probe_fetch "https://www.google.com"
grep -q -- '--socks5-hostname 127.0.0.1:2090' "$CURL_LOG" || {
  echo "FAIL: probe_fetch must use --socks5-hostname 127.0.0.1:\$SOCKS_PORT (log: $(cat "$CURL_LOG"))" >&2
  exit 1
}
grep -q -- '-m 5' "$CURL_LOG" || {
  echo "FAIL: probe_fetch must pass -m \$SPUR_HEALTH_TIMEOUT (log: $(cat "$CURL_LOG"))" >&2
  exit 1
}
grep -q -- '-o /dev/null' "$CURL_LOG" || {
  echo "FAIL: probe_fetch must discard body with -o /dev/null (log: $(cat "$CURL_LOG"))" >&2
  exit 1
}
grep -q 'https://www.google.com' "$CURL_LOG" || {
  echo "FAIL: probe_fetch must request the given URL (log: $(cat "$CURL_LOG"))" >&2
  exit 1
}

# --- _port_is_up invokes ss with separate filter tokens (sport, =, :port) ---
SS_LOG="$(mktemp)"
export SS_LOG
cat > "$FAKEBIN/ss" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${SS_LOG:?}"
printf 'LISTEN\n'
exit 0
EOF
chmod +x "$FAKEBIN/ss"

: > "$SS_LOG"
PATH="$FAKEBIN:$PATH" _port_is_up 1090 || {
  echo "FAIL: _port_is_up should succeed when stub ss reports a listener" >&2
  exit 1
}
grep -qx 'sport' "$SS_LOG" || {
  echo "FAIL: ss must receive sport as a separate argv (log: $(tr '\n' ' ' < "$SS_LOG"))" >&2
  exit 1
}
grep -qx '=' "$SS_LOG" || {
  echo "FAIL: ss must receive = as a separate argv (log: $(tr '\n' ' ' < "$SS_LOG"))" >&2
  exit 1
}
grep -qx ':1090' "$SS_LOG" || {
  echo "FAIL: ss must receive :1090 as a separate argv (log: $(tr '\n' ' ' < "$SS_LOG"))" >&2
  exit 1
}
grep -qx 'sport = :1090' "$SS_LOG" && {
  echo "FAIL: ss filter must not be passed as one combined argv" >&2
  exit 1
}
grep -qx -- '-H' "$SS_LOG" || {
  echo "FAIL: ss must receive -H to suppress header-only output (log: $(tr '\n' ' ' < "$SS_LOG"))" >&2
  exit 1
}

# Header-only / no listener → _port_is_up must fail (ss -H yields empty stdout).
cat > "$FAKEBIN/ss" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${SS_LOG:?}"
exit 0
EOF
chmod +x "$FAKEBIN/ss"

: > "$SS_LOG"
PATH="$FAKEBIN:$PATH" assert_fail _port_is_up 1090

# Remaining cases stub probe_fetch / process / ports — no network.
probe_fetch() {
  case "$1" in
    *example*) return "${STUB_EX:-1}" ;;
    *wikipedia*) return "${STUB_WK:-0}" ;;
    *google*) return "${STUB_GOOGLE:-0}" ;;
    *)
      echo "FAIL: unexpected probe url: $1" >&2
      return 1
      ;;
  esac
}

process_alive() { return "${STUB_PROCESS:-0}"; }
ports_up() { return "${STUB_PORTS:-0}"; }

reset_health() {
  STUB_EX=1
  STUB_WK=0
  STUB_GOOGLE=0
  STUB_PROCESS=0
  STUB_PORTS=0
  record_probe_result ok
}

# example.com down + wikipedia up → secondary probe still ok (any URL).
reset_health
STUB_EX=1
STUB_WK=0
assert_ok probe_secondary
assert_ok probe_primary
assert_ok probes_ok

# Both blocked URLs down → secondary probe fails.
reset_health
STUB_EX=1
STUB_WK=1
assert_fail probe_secondary
assert_ok probe_primary
assert_fail probes_ok

# Google down → primary probe fails; secondary probe can still pass.
reset_health
STUB_GOOGLE=1
assert_fail probe_primary
assert_ok probe_secondary
assert_fail probes_ok

# Three consecutive probe fails at SPUR_PROBE_FAILS=3 → unhealthy.
reset_health
record_probe_result fail
assert_fail probe_unhealthy
record_probe_result fail
assert_fail probe_unhealthy
record_probe_result fail
assert_ok probe_unhealthy

# One success resets the fail counter to 0.
reset_health
record_probe_result fail
record_probe_result fail
record_probe_result ok
assert_fail probe_unhealthy
record_probe_result fail
record_probe_result fail
assert_fail probe_unhealthy
record_probe_result fail
assert_ok probe_unhealthy

# tunnel_is_healthy: process && ports && !probe_unhealthy after a fresh probe.
reset_health
assert_ok tunnel_is_healthy

STUB_PROCESS=1
assert_fail tunnel_is_healthy
STUB_PROCESS=0
STUB_PORTS=1
assert_fail tunnel_is_healthy
STUB_PORTS=0

# Google down becomes unhealthy only after hysteresis.
reset_health
STUB_GOOGLE=1
assert_ok tunnel_is_healthy
assert_ok tunnel_is_healthy
assert_fail tunnel_is_healthy

# example.com down + wikipedia up stays healthy (blocked any-of + open ok).
reset_health
STUB_EX=1
STUB_WK=0
STUB_GOOGLE=0
assert_ok tunnel_is_healthy
assert_ok tunnel_is_healthy
assert_ok tunnel_is_healthy

# Real process_alive / ports_up implementations exist for the container.
grep -q 'pgrep -x sing-box' "$HEALTH" || {
  echo "FAIL: process_alive must use pgrep -x sing-box" >&2
  exit 1
}
grep -Eq '1090' "$HEALTH" || {
  echo "FAIL: ports_up must check SOCKS 1090" >&2
  exit 1
}
grep -Eq '8128' "$HEALTH" || {
  echo "FAIL: ports_up must check HTTP 8128" >&2
  exit 1
}
grep -q 'write_health' "$HEALTH" || {
  echo "FAIL: write_health from Task 6 must remain" >&2
  exit 1
}
