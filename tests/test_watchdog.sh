#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/helpers.sh
. "$ROOT/tests/helpers.sh"

WATCHDOG="$ROOT/docker/watchdog.sh"
if [ ! -f "$WATCHDOG" ]; then
  echo "FAIL: docker/watchdog.sh not found" >&2
  exit 1
fi

# shellcheck source=docker/watchdog.sh
. "$WATCHDOG"

SPUR_RECONNECT_BACKOFF_MAX=8
assert_eq "$(backoff_seconds 1)" "1" "first backoff"
assert_eq "$(backoff_seconds 2)" "2" "second backoff"
assert_eq "$(backoff_seconds 3)" "4" "third backoff"
assert_eq "$(backoff_seconds 5)" "8" "capped backoff"
high_backoff="$(backoff_seconds 64)"
assert_eq "$high_backoff" "8" "high attempt stays at cap"
case "$high_backoff" in
  ''|-*) echo "FAIL: backoff_seconds 64 is empty or negative ('$high_backoff')" >&2; exit 1 ;;
esac
huge_backoff="$(backoff_seconds 999999999999)"
assert_eq "$huge_backoff" "8" "huge attempt stays at cap"
case "$huge_backoff" in
  ''|-*) echo "FAIL: backoff_seconds huge attempt is empty or negative ('$huge_backoff')" >&2; exit 1 ;;
esac

sat_point="$(_fail_attempt_saturation)"
FAIL_ATTEMPT=$sat_point
before_sat=$FAIL_ATTEMPT
increment_fail_attempt
assert_eq "$FAIL_ATTEMPT" "$before_sat" "fail attempt saturates at max backoff"

FAIL_ATTEMPT=9223372036854775806
increment_fail_attempt
near_max_backoff="$(backoff_seconds "$FAIL_ATTEMPT")"
assert_eq "$near_max_backoff" "8" "near-max fail attempt backoff stays capped"
case "$near_max_backoff" in
  ''|-*) echo "FAIL: near-max FAIL_ATTEMPT backoff is empty or negative ('$near_max_backoff')" >&2; exit 1 ;;
esac

# Huge cap above 2^62: saturation stays finite; large-attempt backoff is non-negative.
SPUR_RECONNECT_BACKOFF_MAX=4611686018427387905
huge_cap_sat="$(_fail_attempt_saturation)"
case "$huge_cap_sat" in
  ''|*[!0-9]*)
    echo "FAIL: huge-cap saturation is not a finite integer ('$huge_cap_sat')" >&2
    exit 1
    ;;
esac
if [ "$huge_cap_sat" -lt 1 ]; then
  echo "FAIL: huge-cap saturation is not positive ('$huge_cap_sat')" >&2
  exit 1
fi
huge_cap_backoff="$(backoff_seconds 999999999999)"
case "$huge_cap_backoff" in
  ''|-*)
    echo "FAIL: huge-cap backoff for large attempt is empty or negative ('$huge_cap_backoff')" >&2
    exit 1
    ;;
esac
SPUR_RECONNECT_BACKOFF_MAX=8

assert_ok maybe_timer_upgrade

# restart_singbox must wait for the fresh process to listen before returning,
# so the next tick does not kill a still-starting sing-box.
restart_log=""
pkill() { restart_log="${restart_log}pkill:"; }
start_singbox() { restart_log="${restart_log}start:"; }
wait_for_port() { restart_log="${restart_log}wait$1:"; }
SOCKS_PORT=1090 HTTP_PORT=8128 restart_singbox
assert_eq "$restart_log" "pkill:start:wait1090:wait8128:" "restart waits for both ports after start"
unset -f pkill start_singbox wait_for_port

health_dir="$(mktemp -d)"
export SPUR_HEALTH_FILE="$health_dir/health"
export STOPPING=0
export SPUR_CURRENT_SERVER="nl-1"

switch_calls=0
switch_to=""
restart_calls=0
upgrade_calls=0
refresh_calls=0
health_ok=1
process_ok=1
ports_ok=1

tunnel_is_healthy() { [ "${health_ok:-1}" = 1 ]; }
process_alive() { [ "${process_ok:-1}" = 1 ]; }
ports_up() { [ "${ports_ok:-1}" = 1 ]; }
clash_current() { echo "${SPUR_CURRENT_SERVER:-nl-1}"; }
clash_members() { printf '%s\n' "nl-1" "us-1" "de-1"; }
clash_delay() { echo 0; }
clash_switch() {
  switch_calls=$((switch_calls + 1))
  switch_to="$1"
}
restart_singbox() { restart_calls=$((restart_calls + 1)); }
maybe_timer_upgrade() { upgrade_calls=$((upgrade_calls + 1)); }
maybe_refresh_sub() { refresh_calls=$((refresh_calls + 1)); }

assert_eq "$(pick_next_server)" "us-1" "next member after current"
SPUR_CURRENT_SERVER="us-1"
assert_eq "$(pick_next_server)" "de-1" "next after middle member"
SPUR_CURRENT_SERVER="de-1"
assert_eq "$(pick_next_server)" "nl-1" "wrap to first when current is last"

clash_members() { echo "only-1"; }
SPUR_CURRENT_SERVER="only-1"
assert_eq "$(pick_next_server)" "only-1" "single node stays on itself"
clash_members() { printf '%s\n' "nl-1" "us-1" "de-1"; }
SPUR_CURRENT_SERVER="nl-1"

# Healthy tick: no switch, health ok, fail streak reset, timer hook runs.
FAIL_ATTEMPT=4
switch_calls=0
restart_calls=0
upgrade_calls=0
refresh_calls=0
health_ok=1
watchdog_tick
assert_eq "$switch_calls" "0" "healthy tick does not switch"
assert_eq "$restart_calls" "0" "healthy tick does not restart"
assert_eq "$FAIL_ATTEMPT" "0" "healthy tick resets FAIL_ATTEMPT"
assert_eq "$upgrade_calls" "1" "healthy tick calls maybe_timer_upgrade"
assert_eq "$refresh_calls" "1" "healthy tick calls maybe_refresh_sub"
assert_eq "$(grep -E '^state=' "$SPUR_HEALTH_FILE" | cut -d= -f2)" "ok" "healthy tick writes ok"

# Refresh errors must not turn a healthy tick into failover.
maybe_refresh_sub() { return 1; }
switch_calls=0
restart_calls=0
assert_ok watchdog_tick
assert_eq "$switch_calls" "0" "failed refresh does not failover"
assert_eq "$restart_calls" "0" "failed refresh does not restart"
maybe_refresh_sub() { refresh_calls=$((refresh_calls + 1)); }

# Unhealthy → switch next; if then healthy, write ok and do not restart.
FAIL_ATTEMPT=0
switch_calls=0
restart_calls=0
upgrade_calls=0
refresh_calls=0
health_ok=0
clash_switch() {
  switch_calls=$((switch_calls + 1))
  switch_to="$1"
  health_ok=1
}
watchdog_tick
assert_eq "$switch_calls" "1" "unhealthy tick switches once"
assert_eq "$switch_to" "us-1" "unhealthy tick switches to next member"
assert_eq "$SPUR_CURRENT_SERVER" "us-1" "failover sets SPUR_CURRENT_SERVER"
assert_eq "$restart_calls" "0" "successful switch does not restart"
assert_eq "$upgrade_calls" "0" "unhealthy tick does not call maybe_timer_upgrade"
if [ "$refresh_calls" -lt 1 ]; then
  echo "FAIL: unhealthy tick must refresh subscription (got refresh_calls=$refresh_calls)" >&2
  exit 1
fi
assert_eq "$(grep -E '^state=' "$SPUR_HEALTH_FILE" | cut -d= -f2)" "ok" "healthy after successful switch"

# STOPPING does not failover.
STOPPING=1
SPUR_CURRENT_SERVER="nl-1"
health_ok=0
before=$switch_calls
watchdog_tick
assert_eq "$switch_calls" "$before" "no failover while stopping"

# After unsuccessful switch, health is not ok and restart_singbox runs.
STOPPING=0
FAIL_ATTEMPT=0
switch_calls=0
restart_calls=0
health_ok=0
clash_switch() {
  switch_calls=$((switch_calls + 1))
  switch_to="$1"
}
watchdog_tick || true
probe_state="$(grep -E '^state=' "$SPUR_HEALTH_FILE" | cut -d= -f2)"
if [ "$probe_state" = "ok" ]; then
  echo "FAIL: health is ok after unsuccessful switch" >&2
  exit 1
fi
case "$probe_state" in
  down|reconnecting) ;;
  *)
    echo "FAIL: after unsuccessful switch expected down|reconnecting (got '$probe_state')" >&2
    exit 1
    ;;
esac
assert_eq "$switch_calls" "1" "unsuccessful path still switches"
assert_eq "$SPUR_CURRENT_SERVER" "us-1" "unsuccessful switch still records next server"
assert_eq "$restart_calls" "1" "unsuccessful switch restarts sing-box"

# Mock mode renders a direct-only config without clash_api, so secondary probes
# always fail: the tick must report ok and never touch sing-box or the selector.
STOPPING=0
SPUR_MOCK=1
FAIL_ATTEMPT=3
switch_calls=0
restart_calls=0
upgrade_calls=0
refresh_calls=0
failover_calls=0
failover_now() { failover_calls=$((failover_calls + 1)); }
health_ok=0
SPUR_CURRENT_SERVER="nl-1"
assert_ok watchdog_tick
assert_eq "$failover_calls" "0" "mock tick does not failover"
assert_eq "$switch_calls" "0" "mock tick does not switch selector"
assert_eq "$restart_calls" "0" "mock tick does not restart sing-box"
assert_eq "$upgrade_calls" "0" "mock tick does not probe delays"
assert_eq "$refresh_calls" "0" "mock tick does not refresh subscription"
assert_eq "$FAIL_ATTEMPT" "0" "mock tick resets FAIL_ATTEMPT"
assert_eq "$(grep -E '^state=' "$SPUR_HEALTH_FILE" | cut -d= -f2)" "ok" "mock tick writes ok"

# Mock mode still supervises sing-box itself even though probes and Clash are
# disabled: a dead process must trigger a restart without failover.
FAIL_ATTEMPT=0
switch_calls=0
restart_calls=0
failover_calls=0
process_ok=0
assert_fail watchdog_tick
assert_eq "$restart_calls" "1" "mock tick restarts dead sing-box"
assert_eq "$switch_calls" "0" "mock dead process does not switch selector"
assert_eq "$failover_calls" "0" "mock dead process does not failover"
mock_dead_state="$(grep -E '^state=' "$SPUR_HEALTH_FILE" | cut -d= -f2)"
case "$mock_dead_state" in
  down|reconnecting) ;;
  *)
    echo "FAIL: mock dead process expected down|reconnecting (got '$mock_dead_state')" >&2
    exit 1
    ;;
esac
process_ok=1
SPUR_MOCK=0
unset -f failover_now

rm -rf "$health_dir"

# SIGTERM during sleep must set STOPPING and exit promptly without failover.
sigterm_dir="$(mktemp -d)"
sigterm_health="$sigterm_dir/health"
sigterm_script="$sigterm_dir/loop.sh"
sigterm_switch_log="$sigterm_dir/switch.log"
cat > "$sigterm_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export SPUR_HEALTH_FILE="$sigterm_health"
export SPUR_HEALTH_INTERVAL=15
export STOPPING=0
export SPUR_CURRENT_SERVER="nl-1"
. "$ROOT/docker/watchdog.sh"
tunnel_is_healthy() { return 0; }
clash_current() { echo nl-1; }
clash_members() { printf '%s\n' "nl-1" "us-1"; }
clash_delay() { echo 0; }
clash_switch() { echo switched >> "$sigterm_switch_log"; }
restart_singbox() { :; }
bootstrap_selector() { :; }
write_health ok
watchdog_loop
EOF
chmod +x "$sigterm_script"
bash "$sigterm_script" &
sigterm_pid=$!
sleep 0.3
kill -TERM "$sigterm_pid" 2>/dev/null || true
waited=0
while [ "$waited" -lt 20 ]; do
  if ! kill -0 "$sigterm_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
  waited=$((waited + 1))
done
if kill -0 "$sigterm_pid" 2>/dev/null; then
  kill -KILL "$sigterm_pid" 2>/dev/null || true
  wait "$sigterm_pid" 2>/dev/null || true
  rm -rf "$sigterm_dir"
  echo "FAIL: watchdog_loop did not exit promptly after SIGTERM" >&2
  exit 1
fi
wait "$sigterm_pid" 2>/dev/null || true
if [ -s "$sigterm_switch_log" ]; then
  rm -rf "$sigterm_dir"
  echo "FAIL: SIGTERM triggered failover" >&2
  exit 1
fi
sigterm_state="$(grep -E '^state=' "$sigterm_health" | cut -d= -f2)"
rm -rf "$sigterm_dir"
assert_eq "$sigterm_state" "down" "SIGTERM during sleep writes state=down promptly"

# --- hysteresis counts ticks: one probe round per tick ---
# shellcheck source=docker/watchdog.sh
. "$WATCHDOG"
probe_dir="$(mktemp -d)"
export SPUR_HEALTH_FILE="$probe_dir/health"
STOPPING=0
SPUR_MOCK=0
SPUR_CURRENT_SERVER="nl-1"
LAST_ROTATE_CHECK=0
SPUR_ROTATE_INTERVAL=0
probe_calls=0
probe_healthy=1
tunnel_is_healthy() {
  probe_calls=$((probe_calls + 1))
  [ "$probe_healthy" = 1 ]
}
clash_current() { echo "${SPUR_CURRENT_SERVER:-nl-1}"; }
clash_members() { printf '%s\n' "nl-1" "us-1"; }
clash_delay() { echo 200; }
clash_switch() { SPUR_CURRENT_SERVER="$1"; }
maybe_refresh_sub() { :; }
restart_singbox() { :; }

watchdog_tick
assert_eq "$probe_calls" "1" "healthy tick measures probes once"

probe_calls=0
probe_healthy=0
LAST_ROTATE_CHECK=0
watchdog_tick || true
assert_eq "$probe_calls" "2" "unhealthy tick measures once before and once after failover"

rm -rf "$probe_dir"

# pick_fastest_server prefers the lowest positive Clash delay among Vision tags.
_vision_tags() { printf '%s\n' "vision-slow" "vision-fast"; }
_probe_delays() { printf '%s\n' "vision-slow 400" "vision-fast 80"; }
assert_eq "$(pick_fastest_server)" "vision-fast" "pick_fastest chooses lowest Vision delay"
_vision_tags() { return 0; }
_probe_delays() { return 0; }

grep -q 'watchdog_loop' "$ROOT/docker/entrypoint.sh" || {
  echo "FAIL: entrypoint.sh must call watchdog_loop" >&2
  exit 1
}
if grep -q 'exec "\$watchdog"' "$ROOT/docker/entrypoint.sh"; then
  echo "FAIL: entrypoint.sh must source watchdog and call watchdog_loop, not exec" >&2
  exit 1
fi
grep -q 'watchdog.sh' "$ROOT/Dockerfile" || {
  echo "FAIL: Dockerfile must COPY docker/watchdog.sh" >&2
  exit 1
}
grep -q 'entrypoint.sh' "$ROOT/docker/watchdog.sh" || {
  echo "FAIL: watchdog.sh must document which functions entrypoint.sh provides" >&2
  exit 1
}
