#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${SPUR_LIB_DIR:-/usr/local/lib/spur-gw}"
if [ ! -f "$LIB_DIR/health.sh" ]; then
  LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
# shellcheck source=docker/health.sh
. "$LIB_DIR/health.sh"

wait_for_port() {
  local port="$1" tries="${2:-50}" i=0
  while [ "$i" -lt "$tries" ]; do
    if command -v nc >/dev/null 2>&1; then
      nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && return 0
    else
      (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null && return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Renders into "$config_json.tmp" and only moves it into place once the whole
# pipeline succeeded: a failed refresh must leave the running config untouched.
fetch_and_render() {
  local render_py="${SPUR_RENDER_PY:-$LIB_DIR/render_config.py}"
  local config_json="${SPUR_CONFIG_JSON:-/var/lib/spur/config.json}"
  local socks="${SOCKS_PORT:-1090}"
  local http="${HTTP_PORT:-8128}"
  local tmp="${config_json}.tmp"
  local sub="${config_json}.sub"

  mkdir -p "$(dirname "$config_json")"
  if [ "${SPUR_MOCK:-0}" = "1" ]; then
    if ! echo | python3 "$render_py" --mock --socks-port "$socks" --http-port "$http" > "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    commit_config "$tmp" "$config_json"
    return
  fi

  if [ -z "${SPUR_SUB_URL:-}" ]; then
    echo "SPUR_SUB_URL is required" >&2
    return 1
  fi
  if ! curl -fsSL "$SPUR_SUB_URL" -o "$sub"; then
    echo "subscription fetch failed: $SPUR_SUB_URL" >&2
    rm -f "$sub" "$tmp"
    return 1
  fi
  if ! python3 "$render_py" --socks-port "$socks" --http-port "$http" < "$sub" > "$tmp"; then
    rm -f "$sub" "$tmp"
    return 1
  fi
  rm -f "$sub"
  commit_config "$tmp" "$config_json"
}

# Validates the candidate config when sing-box is available, then replaces the
# live config with a single rename.
commit_config() {
  local tmp="$1" config_json="$2"
  if command -v sing-box >/dev/null 2>&1; then
    if ! sing-box check -c "$tmp"; then
      echo "rendered config rejected by sing-box check" >&2
      rm -f "$tmp"
      return 1
    fi
  fi
  mv -f "$tmp" "$config_json"
}

start_singbox() {
  local config_json="${SPUR_CONFIG_JSON:-/var/lib/spur/config.json}"
  sing-box check -c "$config_json"
  sing-box run -c "$config_json" &
  SING_BOX_PID=$!
}

entrypoint_main() {
  mkdir -p /var/lib/spur /run
  fetch_and_render
  start_singbox
  local socks="${SOCKS_PORT:-1090}"
  local http="${HTTP_PORT:-8128}"
  wait_for_port "$socks" || { echo "SOCKS proxy failed to listen on $socks" >&2; exit 1; }
  wait_for_port "$http" || { echo "HTTP proxy failed to listen on $http" >&2; exit 1; }
  local watchdog="${SPUR_WATCHDOG:-$LIB_DIR/watchdog.sh}"
  if [ -f "$watchdog" ]; then
    # shellcheck source=docker/watchdog.sh
    . "$watchdog"
    # bootstrap_selector + write_health ok run at the start of watchdog_loop
    watchdog_loop
    return 0
  fi
  write_health ok
  wait
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  entrypoint_main "$@"
fi
