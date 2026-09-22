#!/usr/bin/env bash
# Sourced by docker/entrypoint.sh, which also provides start_singbox,
# fetch_and_render and wait_for_port. This file never sources entrypoint.sh.
_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docker/health.sh
. "$_WATCHDOG_DIR/health.sh"
# shellcheck source=docker/clash.sh
. "$_WATCHDOG_DIR/clash.sh"

backoff_seconds() {
  local attempt="$1" cap="${SPUR_RECONNECT_BACKOFF_MAX:-60}" delay=1 i
  # Signed 64-bit max / 2: the next delay*2 would overflow.
  local overflow_guard=4611686018427387903
  i=1
  while [ "$i" -lt "$attempt" ]; do
    if [ "$delay" -ge "$cap" ] || [ "$delay" -gt "$overflow_guard" ]; then
      echo "$cap"
      return 0
    fi
    delay=$((delay * 2))
    i=$((i + 1))
  done
  if [ "$delay" -lt 1 ] || [ "$delay" -gt "$cap" ]; then
    echo "$cap"
  else
    echo "$delay"
  fi
}

_fail_attempt_saturation() {
  local cap="${SPUR_RECONNECT_BACKOFF_MAX:-60}" delay=1 attempt=1
  # Signed 64-bit max / 2: the next delay*2 would overflow.
  local overflow_guard=4611686018427387903
  while true; do
    if [ "$delay" -ge "$cap" ] || [ "$delay" -gt "$overflow_guard" ] || [ "$delay" -lt 1 ]; then
      echo "$attempt"
      return 0
    fi
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

increment_fail_attempt() {
  local overflow_max=9223372036854775807
  local saturation current next
  saturation="$(_fail_attempt_saturation)"
  current="${FAIL_ATTEMPT:-0}"

  if [ "$current" -ge "$saturation" ] || [ "$current" -ge "$overflow_max" ]; then
    if [ "$current" -gt "$overflow_max" ]; then
      FAIL_ATTEMPT=$overflow_max
    else
      FAIL_ATTEMPT=$saturation
    fi
    return 0
  fi

  next=$((current + 1))
  if [ "$next" -lt 0 ]; then
    FAIL_ATTEMPT=$overflow_max
    return 0
  fi
  if [ "$next" -ge "$saturation" ]; then
    FAIL_ATTEMPT=$saturation
  else
    FAIL_ATTEMPT=$next
  fi
}

# tunnel_is_healthy runs the probes and moves the hysteresis counter, so a
# tick measures once and every consumer inside that tick reuses the verdict.
tick_health_reset() {
  TICK_HEALTHY=""
}

tick_is_healthy() {
  if [ -z "${TICK_HEALTHY:-}" ]; then
    if tunnel_is_healthy; then
      TICK_HEALTHY=1
    else
      TICK_HEALTHY=0
    fi
  fi
  [ "$TICK_HEALTHY" = 1 ]
}

noticeably_better() {
  local cur_ms="$1" other_ms="$2"
  local min_ms="${SPUR_UPGRADE_MIN_IMPROVE_MS:-80}"
  local min_ratio="${SPUR_UPGRADE_MIN_IMPROVE_RATIO:-0.3}"
  python3 -c '
import sys
cur = int(sys.argv[1])
other = int(sys.argv[2])
min_ms = int(sys.argv[3])
ratio = float(sys.argv[4])
if other == 0 or cur == 0:
    raise SystemExit(1)
if (cur - other) >= min_ms or other <= cur * (1 - ratio):
    raise SystemExit(0)
raise SystemExit(1)
' "$cur_ms" "$other_ms" "$min_ms" "$min_ratio"
}

maybe_timer_upgrade() {
  local now interval current cur_ms member other_ms
  now="$(date +%s)"
  interval="${SPUR_ROTATE_INTERVAL:-1800}"
  if [ -z "${LAST_ROTATE_CHECK:-}" ]; then
    LAST_ROTATE_CHECK="$now"
    return 0
  fi
  if [ $((now - LAST_ROTATE_CHECK)) -lt "$interval" ]; then
    return 0
  fi
  LAST_ROTATE_CHECK="$now"

  # Failover owns an unhealthy current; the timer never tears it down.
  if ! tick_is_healthy; then
    return 0
  fi

  current="$(clash_current)"
  cur_ms="$(clash_delay "$current")"
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    [ "$member" = "$current" ] && continue
    other_ms="$(clash_delay "$member")"
    if noticeably_better "$cur_ms" "$other_ms"; then
      clash_switch "$member" || true
      SPUR_CURRENT_SERVER="$member"
      return 0
    fi
  done <<EOF
$(clash_members)
EOF
}

_proxy_tag_set() {
  local config="${SPUR_CONFIG_JSON:-/var/lib/spur/config.json}"
  if [ ! -f "$config" ]; then
    return 0
  fi
  python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
for ob in cfg.get("outbounds", []):
    if ob.get("type") == "selector" and ob.get("tag") == "proxy":
        print("\n".join(sorted(ob.get("outbounds") or [])))
        break
' "$config" || true
}

check_singbox_config() {
  sing-box check -c "${SPUR_CONFIG_JSON:-/var/lib/spur/config.json}"
}

maybe_refresh_sub() {
  local force="${1:-0}"
  local now interval before after current cooldown
  now="$(date +%s)"
  interval="${SPUR_SUB_REFRESH_INTERVAL:-86400}"
  cooldown="${SPUR_SUB_REFRESH_FAIL_COOLDOWN:-900}"

  if [ "$force" = "1" ]; then
    if [ -n "${LAST_FORCE_SUB_REFRESH:-}" ] \
      && [ $((now - LAST_FORCE_SUB_REFRESH)) -lt "$cooldown" ]; then
      return 0
    fi
    LAST_FORCE_SUB_REFRESH="$now"
    LAST_SUB_REFRESH="$now"
  else
    if [ -z "${LAST_SUB_REFRESH:-}" ]; then
      LAST_SUB_REFRESH="$now"
      return 0
    fi
    if [ $((now - LAST_SUB_REFRESH)) -lt "$interval" ]; then
      return 0
    fi
    LAST_SUB_REFRESH="$now"
  fi

  before="$(_proxy_tag_set)"
  fetch_and_render || return 0
  after="$(_proxy_tag_set)"
  if [ "$before" = "$after" ]; then
    return 0
  fi
  check_singbox_config || return 0
  # SIGHUP if we have a tracked pid; otherwise full restart.
  if [ -n "${SING_BOX_PID:-}" ] && kill -HUP "$SING_BOX_PID" 2>/dev/null; then
    :
  else
    restart_singbox
  fi
  current="$(clash_current)"
  if printf '%s\n' "$after" | grep -qxF -- "$current"; then
    clash_switch "$current" || true
    SPUR_CURRENT_SERVER="$current"
  fi
}

_vision_tags() {
  local config="${SPUR_CONFIG_JSON:-/var/lib/spur/config.json}"
  if [ ! -f "$config" ]; then
    return 0
  fi
  python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
for ob in cfg.get("outbounds", []):
    if ob.get("type") == "vless" and ob.get("flow") == "xtls-rprx-vision":
        print(ob.get("tag") or "")
' "$config" 2>/dev/null || true
}

# Parallel Clash delay probe; prints "tag ms" lines for positive delays.
_probe_delays() {
  local base timeout_ms tags
  base="${SPUR_CLASH_API:-127.0.0.1:9090}"
  timeout_ms="${1:-3000}"
  shift || true
  tags="$(cat)"
  SPUR_CLASH_API="$base" SPUR_DELAY_TIMEOUT_MS="$timeout_ms" python3 -c '
import json, os, sys, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

base = os.environ.get("SPUR_CLASH_API", "127.0.0.1:9090")
timeout_ms = int(os.environ.get("SPUR_DELAY_TIMEOUT_MS", "3000"))
tags = [line.strip() for line in sys.stdin if line.strip()]
if not tags:
    raise SystemExit(0)

def delay(tag):
    enc = urllib.parse.quote(tag, safe="")
    url = f"http://{base}/proxies/{enc}/delay?url=https://www.gstatic.com/generate_204&timeout={timeout_ms}"
    try:
        with urllib.request.urlopen(url, timeout=(timeout_ms / 1000) + 1) as resp:
            data = json.load(resp)
        value = int(data.get("delay") or 0)
        return tag, value
    except Exception:
        return tag, 0

workers = min(8, max(1, len(tags)))
with ThreadPoolExecutor(max_workers=workers) as pool:
    futures = [pool.submit(delay, tag) for tag in tags]
    for fut in as_completed(futures):
        tag, value = fut.result()
        if value > 0:
            print(f"{tag} {value}")
' <<< "$tags"
}

pick_fastest_server() {
  local best="" best_ms=0 member ms line
  local candidates=""
  candidates="$(_vision_tags)"
  if [ -z "$(printf '%s' "$candidates" | tr -d '[:space:]')" ]; then
    candidates="$(clash_members)"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    member="${line%% *}"
    ms="${line##* }"
    case "$ms" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ -z "$best" ] || [ "$ms" -lt "$best_ms" ]; then
      best="$member"
      best_ms="$ms"
    fi
  done <<EOF
$(_probe_delays 3000 <<< "$candidates")
EOF
  if [ -n "$best" ]; then
    printf '%s\n' "$best"
    return 0
  fi
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    printf '%s\n' "$member"
    return 0
  done <<EOF
$candidates
EOF
  clash_current
}

bootstrap_selector() {
  local best
  if [ "${SPUR_MOCK:-0}" = "1" ]; then
    return 0
  fi
  best="$(pick_fastest_server)" || return 0
  [ -n "$best" ] || return 0
  clash_switch "$best" || true
  SPUR_CURRENT_SERVER="$best"
}

pick_next_server() {
  local current first="" seen=0 member
  current="$(clash_current)"
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    if [ -z "$first" ]; then
      first="$member"
    fi
    if [ "$seen" -eq 1 ]; then
      echo "$member"
      return 0
    fi
    if [ "$member" = "$current" ]; then
      seen=1
    fi
  done <<EOF
$(clash_members)
EOF
  if [ -n "$first" ]; then
    echo "$first"
  else
    echo "$current"
  fi
}

restart_singbox() {
  pkill -x sing-box 2>/dev/null || true
  start_singbox
  # Block until the fresh process listens, otherwise the next tick sees a
  # half-started sing-box and kills it again.
  wait_for_port "${SOCKS_PORT:-1090}" || echo "sing-box did not listen on SOCKS after restart" >&2
  wait_for_port "${HTTP_PORT:-8128}" || echo "sing-box did not listen on HTTP after restart" >&2
  return 0
}

failover_now() {
  local reason="${1:-tunnel unhealthy}"
  local next
  # Prefer a Vision node with a real Clash delay when one exists.
  next="$(pick_fastest_server)"
  if [ -z "$next" ] || [ "$next" = "$(clash_current)" ]; then
    next="$(pick_next_server)"
  fi
  clash_switch "$next" || true
  SPUR_CURRENT_SERVER="$next"
  # The node changed, so the tick's verdict is stale: measure the new path once.
  tick_health_reset
  if tick_is_healthy; then
    write_health ok
    FAIL_ATTEMPT=0
    return 0
  fi
  increment_fail_attempt
  restart_singbox
  write_health down "$reason"
  return 1
}

watchdog_tick() {
  if [ "${STOPPING:-0}" = 1 ]; then
    return 0
  fi
  # The mock config routes everything direct and exposes no clash_api, so the
  # secondary probes and the selector are both meaningless here.
  if [ "${SPUR_MOCK:-0}" = "1" ]; then
    if process_alive && ports_up; then
      FAIL_ATTEMPT=0
      write_health ok
      return 0
    fi
    write_health reconnecting "sing-box unavailable"
    increment_fail_attempt
    restart_singbox
    write_health down "sing-box unavailable"
    return 1
  fi
  tick_health_reset
  if tick_is_healthy; then
    FAIL_ATTEMPT=0
    write_health ok
    maybe_timer_upgrade
    maybe_refresh_sub || true
    return 0
  fi
  write_health reconnecting "tunnel unhealthy"
  # Re-fetch subscription even while down: provider Reality params rotate often.
  maybe_refresh_sub || true
  maybe_refresh_sub 1 || true
  failover_now "tunnel unhealthy"
}

_interruptible_sleep() {
  sleep "$1" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" || true
  unset SLEEP_PID
}

watchdog_loop() {
  FAIL_ATTEMPT=0
  LAST_ROTATE_CHECK="${LAST_ROTATE_CHECK:-$(date +%s)}"
  LAST_SUB_REFRESH="${LAST_SUB_REFRESH:-$(date +%s)}"
  LAST_FORCE_SUB_REFRESH="${LAST_FORCE_SUB_REFRESH:-0}"
  write_health reconnecting "bootstrapping"
  bootstrap_selector || true
  write_health ok
  while [ "${STOPPING:-0}" != 1 ]; do
    if ! watchdog_tick; then
      _interruptible_sleep "$(backoff_seconds "$FAIL_ATTEMPT")"
    else
      _interruptible_sleep "${SPUR_HEALTH_INTERVAL:-15}"
    fi
  done
}

handle_stop() {
  STOPPING=1
  if [ -n "${SLEEP_PID:-}" ]; then
    kill "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
    unset SLEEP_PID
  fi
  write_health down "stopped"
  exit 0
}

trap handle_stop TERM INT
