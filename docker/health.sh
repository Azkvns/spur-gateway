#!/usr/bin/env bash

write_health() {
  local state="$1" reason="${2:-}" server="${SPUR_CURRENT_SERVER:-}"
  # Prefer the live Clash selector when available so status matches traffic.
  if [ "${SPUR_MOCK:-0}" != "1" ] && declare -F clash_current >/dev/null 2>&1; then
    server="$(clash_current 2>/dev/null || printf '%s' "$server")"
    SPUR_CURRENT_SERVER="$server"
  fi
  printf 'state=%s\nreason=%s\nserver=%s\nupdated=%s\n' \
    "$state" "$reason" "$server" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "${SPUR_HEALTH_FILE:-/run/spur-gw-health}"
}

PROBE_FAIL_COUNT=0

probe_fetch() {
  local url="$1"
  local timeout="${SPUR_HEALTH_TIMEOUT:-8}"
  local port="${SOCKS_PORT:-1090}"
  curl -fsS -o /dev/null -m "$timeout" --socks5-hostname 127.0.0.1:$port "$url"
}

probe_primary() {
  local url="${SPUR_PROBE_PRIMARY:-}"
  [ -n "$url" ] || return 1
  probe_fetch "$url"
}

probe_secondary() {
  local urls url
  urls="${SPUR_PROBE_SECONDARY:-}"
  [ -n "$urls" ] || return 1
  local IFS=,
  for url in $urls; do
    url="${url#"${url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"
    [ -n "$url" ] || continue
    probe_fetch "$url" && return 0
  done
  return 1
}

probes_ok() {
  probe_primary && probe_secondary
}

record_probe_result() {
  local result="$1"
  case "$result" in
    ok)
      PROBE_FAIL_COUNT=0
      ;;
    fail)
      PROBE_FAIL_COUNT=$((${PROBE_FAIL_COUNT:-0} + 1))
      ;;
    *)
      echo "record_probe_result: expected ok|fail" >&2
      return 2
      ;;
  esac
}

probe_unhealthy() {
  [ "${PROBE_FAIL_COUNT:-0}" -ge "${SPUR_PROBE_FAILS:-3}" ]
}

process_alive() {
  pgrep -x sing-box >/dev/null 2>&1
}

_port_is_up() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    [ -n "$(ss -H -lnt sport = :"$port" 2>/dev/null)" ]
  elif command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
  else
    (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null
  fi
}

ports_up() {
  local socks="${SOCKS_PORT:-1090}"
  local http="${HTTP_PORT:-8128}"
  _port_is_up "$socks" && _port_is_up "$http"
}

tunnel_is_healthy() {
  process_alive || return 1
  ports_up || return 1
  if probes_ok; then
    record_probe_result ok
  else
    record_probe_result fail
  fi
  ! probe_unhealthy
}
