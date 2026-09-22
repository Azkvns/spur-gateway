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

export SPUR_UPGRADE_MIN_IMPROVE_MS=80
export SPUR_UPGRADE_MIN_IMPROVE_RATIO=0.3

assert_ok noticeably_better 200 100
assert_fail noticeably_better 200 180
assert_fail noticeably_better 200 0
assert_fail noticeably_better 0 100
assert_fail noticeably_better 0 0

# Timer upgrade stubs: delay probes only, no network.
switch_calls=0
switch_to=""
health_ok=1
SPUR_CURRENT_SERVER="nl-1"
LAST_ROTATE_CHECK=0
SPUR_ROTATE_INTERVAL=0

tunnel_is_healthy() { [ "${health_ok:-1}" = 1 ]; }
clash_current() { echo "${SPUR_CURRENT_SERVER:-nl-1}"; }
clash_members() { printf '%s\n' "nl-1" "us-1"; }
clash_switch() {
  switch_calls=$((switch_calls + 1))
  switch_to="$1"
  SPUR_CURRENT_SERVER="$1"
}
clash_delay() {
  case "$1" in
    nl-1) echo "${DELAY_NL:-200}" ;;
    us-1) echo "${DELAY_US:-300}" ;;
    *) echo 0 ;;
  esac
}

# Other is worse (300ms > 200ms): no switch.
DELAY_NL=200 DELAY_US=300
switch_calls=0
health_ok=1
LAST_ROTATE_CHECK=0
tick_health_reset
maybe_timer_upgrade
assert_eq "$switch_calls" "0" "timer does not switch if other is worse"
assert_eq "$SPUR_CURRENT_SERVER" "nl-1" "current stays when other is worse"

# Other is slightly better but under threshold (200 vs 180): no switch.
DELAY_NL=200 DELAY_US=180
switch_calls=0
LAST_ROTATE_CHECK=0
tick_health_reset
maybe_timer_upgrade
assert_eq "$switch_calls" "0" "timer does not switch if other is not noticeably better"

# Current unhealthy: failover owns that path, timer must not switch even if other is better.
DELAY_NL=200 DELAY_US=100
switch_calls=0
health_ok=0
LAST_ROTATE_CHECK=0
tick_health_reset
maybe_timer_upgrade
assert_eq "$switch_calls" "0" "timer does not switch if current is unhealthy"
assert_eq "$SPUR_CURRENT_SERVER" "nl-1" "unhealthy current is left for failover"

# Noticeably better and healthy: switch to the faster member.
DELAY_NL=200 DELAY_US=100
switch_calls=0
health_ok=1
LAST_ROTATE_CHECK=0
tick_health_reset
maybe_timer_upgrade
assert_eq "$switch_calls" "1" "timer switches when other is noticeably better"
assert_eq "$switch_to" "us-1" "timer switches to the better member"
assert_eq "$SPUR_CURRENT_SERVER" "us-1" "timer records the better member"

# Within rotate interval: skip delay probes and do not switch.
DELAY_NL=200 DELAY_US=100
switch_calls=0
SPUR_CURRENT_SERVER="nl-1"
LAST_ROTATE_CHECK="$(date +%s)"
SPUR_ROTATE_INTERVAL=1800
tick_health_reset
maybe_timer_upgrade
assert_eq "$switch_calls" "0" "timer skips when rotate interval has not elapsed"

# The tick owns the probe measurement; the timer reuses that verdict.
probe_calls=0
tunnel_is_healthy() {
  probe_calls=$((probe_calls + 1))
  [ "${health_ok:-1}" = 1 ]
}
DELAY_NL=200 DELAY_US=300
health_ok=1
SPUR_CURRENT_SERVER="nl-1"
SPUR_ROTATE_INTERVAL=0
LAST_ROTATE_CHECK=0
tick_health_reset
maybe_timer_upgrade
assert_eq "$probe_calls" "1" "timer measures health once without a cached verdict"

probe_calls=0
LAST_ROTATE_CHECK=0
tick_health_reset
assert_ok tick_is_healthy
assert_eq "$probe_calls" "1" "tick verdict costs one measurement"
maybe_timer_upgrade
assert_eq "$probe_calls" "1" "timer reuses the cached tick verdict"

# --- subscription refresh ---
cfg_dir="$(mktemp -d)"
export SPUR_CONFIG_JSON="$cfg_dir/config.json"
trap 'rm -rf "$cfg_dir"' EXIT

write_proxy_tags() {
  local tags="$1"
  python3 -c '
import json, sys
tags = sys.argv[1].split(",")
json.dump({"outbounds": [{"type": "selector", "tag": "proxy", "outbounds": tags}]}, open(sys.argv[2], "w"))
' "$tags" "$SPUR_CONFIG_JSON"
}

restart_calls=0
check_calls=0
fetch_calls=0
refresh_tags="nl-1,us-1"
SPUR_CURRENT_SERVER="nl-1"

write_proxy_tags "nl-1,us-1"
fetch_and_render() {
  fetch_calls=$((fetch_calls + 1))
  write_proxy_tags "$refresh_tags"
}
check_singbox_config() { check_calls=$((check_calls + 1)); }
restart_singbox() { restart_calls=$((restart_calls + 1)); }
clash_current() { echo "${SPUR_CURRENT_SERVER:-nl-1}"; }
clash_switch() {
  switch_calls=$((switch_calls + 1))
  switch_to="$1"
}

LAST_SUB_REFRESH=0
SPUR_SUB_REFRESH_INTERVAL=0
restart_calls=0
check_calls=0
fetch_calls=0
switch_calls=0
maybe_refresh_sub
assert_eq "$fetch_calls" "1" "refresh downloads and re-renders"
assert_eq "$restart_calls" "0" "refresh without tag change does not restart"
assert_eq "$check_calls" "0" "refresh without tag change skips sing-box check"

# Tag set changed: check + restart, keep current tag if still in the pool.
refresh_tags="nl-1,de-1"
write_proxy_tags "nl-1,us-1"
LAST_SUB_REFRESH=0
restart_calls=0
check_calls=0
fetch_calls=0
switch_calls=0
switch_to=""
SPUR_CURRENT_SERVER="nl-1"
maybe_refresh_sub
assert_eq "$fetch_calls" "1" "changed-tag refresh re-renders"
assert_eq "$check_calls" "1" "changed-tag refresh runs sing-box check"
assert_eq "$restart_calls" "1" "changed-tag refresh restarts sing-box"
assert_eq "$switch_calls" "1" "changed-tag refresh keeps current tag still in pool"
assert_eq "$switch_to" "nl-1" "kept tag is the previous current"

# Current tag dropped from pool: restart without forcing a stale switch.
refresh_tags="de-1,us-1"
write_proxy_tags "nl-1,us-1"
LAST_SUB_REFRESH=0
restart_calls=0
switch_calls=0
SPUR_CURRENT_SERVER="nl-1"
maybe_refresh_sub
assert_eq "$restart_calls" "1" "dropped current still restarts"
assert_eq "$switch_calls" "0" "dropped current is not switched back"

# Interval not elapsed: no-op.
LAST_SUB_REFRESH="$(date +%s)"
SPUR_SUB_REFRESH_INTERVAL=86400
fetch_calls=0
restart_calls=0
maybe_refresh_sub
assert_eq "$fetch_calls" "0" "refresh skips when interval has not elapsed"
assert_eq "$restart_calls" "0" "refresh skip does not restart"

# Forced refresh ignores interval but respects fail cooldown.
LAST_SUB_REFRESH="$(date +%s)"
LAST_FORCE_SUB_REFRESH=0
SPUR_SUB_REFRESH_FAIL_COOLDOWN=900
refresh_tags="nl-1,us-1"
write_proxy_tags "nl-1,us-1"
fetch_calls=0
maybe_refresh_sub 1
assert_eq "$fetch_calls" "1" "forced refresh runs despite interval"
fetch_calls=0
LAST_FORCE_SUB_REFRESH="$(date +%s)"
maybe_refresh_sub 1
assert_eq "$fetch_calls" "0" "forced refresh respects cooldown"
