#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/helpers.sh
. "$ROOT/tests/helpers.sh"

HEALTH="$ROOT/docker/health.sh"
ENTRYPOINT="$ROOT/docker/entrypoint.sh"
DOCKERFILE="$ROOT/Dockerfile"
COMPOSE="$ROOT/docker-compose.yml"

if [ ! -f "$HEALTH" ]; then
  echo "FAIL: docker/health.sh not found" >&2
  exit 1
fi

# --- write_health ok → file contains state=ok ---
# shellcheck source=docker/health.sh
. "$HEALTH"
HEALTHF="$(mktemp)"
trap 'rm -f "$HEALTHF"' EXIT
SPUR_HEALTH_FILE="$HEALTHF" write_health ok
grep -q '^state=ok$' "$HEALTHF" || {
  echo "FAIL: write_health ok must write state=ok (got: $(cat "$HEALTHF"))" >&2
  exit 1
}
grep -q '^reason=' "$HEALTHF" || {
  echo "FAIL: write_health must write reason=" >&2
  exit 1
}
grep -q '^server=' "$HEALTHF" || {
  echo "FAIL: write_health must write server=" >&2
  exit 1
}
grep -qE '^updated=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$HEALTHF" || {
  echo "FAIL: write_health must write UTC updated= timestamp (got: $(cat "$HEALTHF"))" >&2
  exit 1
}

# --- Dockerfile contract ---
if [ ! -f "$DOCKERFILE" ]; then
  echo "FAIL: Dockerfile not found" >&2
  exit 1
fi
grep -q 'sing-box' "$DOCKERFILE" || {
  echo "FAIL: Dockerfile must install sing-box" >&2
  exit 1
}
grep -q 'EXPOSE 1090' "$DOCKERFILE" || {
  echo "FAIL: Dockerfile must EXPOSE 1090" >&2
  exit 1
}
grep -q '1.13.14-extended-2.5.0' "$DOCKERFILE" || {
  echo "FAIL: Dockerfile must pin sing-box-extended 1.13.14-extended-2.5.0" >&2
  exit 1
}
grep -q 'shtorm-7/sing-box-extended' "$DOCKERFILE" || {
  echo "FAIL: Dockerfile must download from shtorm-7/sing-box-extended" >&2
  exit 1
}

# --- compose: no NET_ADMIN / tun, clash unpublished, arm64 build-arg ---
if [ ! -f "$COMPOSE" ]; then
  echo "FAIL: docker-compose.yml not found" >&2
  exit 1
fi
if grep -q 'NET_ADMIN' "$COMPOSE"; then
  echo "FAIL: docker-compose.yml must not grant NET_ADMIN" >&2
  exit 1
fi
if grep -q '/dev/net/tun' "$COMPOSE"; then
  echo "FAIL: docker-compose.yml must not mount /dev/net/tun" >&2
  exit 1
fi
if grep -qE '9090' "$COMPOSE"; then
  echo "FAIL: docker-compose.yml must not publish Clash API on the host" >&2
  exit 1
fi
grep -qE 'SING_BOX_ARCH:[[:space:]]*\$\{SING_BOX_ARCH:-arm64\}' "$COMPOSE" || {
  echo "FAIL: compose must pass SING_BOX_ARCH \${SING_BOX_ARCH:-arm64}" >&2
  exit 1
}

# --- fetch_and_render: sourceable, mock skips curl, live requires URL ---
if [ ! -f "$ENTRYPOINT" ]; then
  echo "FAIL: docker/entrypoint.sh not found" >&2
  exit 1
fi
# shellcheck source=docker/entrypoint.sh
. "$ENTRYPOINT"

WORKDIR="$(mktemp -d)"
FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" "$FAKEBIN" "$HEALTHF"' EXIT
cat > "$FAKEBIN/curl" << 'EOF'
#!/usr/bin/env bash
echo "curl was invoked" >&2
exit 99
EOF
chmod +x "$FAKEBIN/curl"

CONFIG="$WORKDIR/config.json"
export SPUR_CONFIG_JSON="$CONFIG"
export SPUR_RENDER_PY="$ROOT/docker/render_config.py"
export SPUR_LIB_DIR="$ROOT/docker"

SPUR_MOCK=1 PATH="$FAKEBIN:$PATH" fetch_and_render
assert_eq "$?" "0" "mock fetch_and_render succeeds"
test -s "$CONFIG" || {
  echo "FAIL: mock fetch_and_render must write config.json" >&2
  exit 1
}
grep -q '"type": "direct"' "$CONFIG" || {
  echo "FAIL: mock config must be direct-only (got: $(cat "$CONFIG"))" >&2
  exit 1
}

rm -f "$CONFIG"
SOCKS_PORT=1190 HTTP_PORT=8228 SPUR_MOCK=1 PATH="$FAKEBIN:$PATH" fetch_and_render
assert_eq "$?" "0" "mock fetch_and_render with custom ports succeeds"
python3 - "$CONFIG" << 'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
ports = {item["type"]: item["listen_port"] for item in cfg["inbounds"]}
if ports.get("socks") != 1190 or ports.get("http") != 8228:
    raise SystemExit(f"FAIL: mock render must use SOCKS_PORT/HTTP_PORT (got {ports})")
PY

rm -f "$CONFIG"
unset SPUR_SUB_URL
set +e
SPUR_MOCK=0 SPUR_SUB_URL="" PATH="$FAKEBIN:$PATH" fetch_and_render
LIVE_RC=$?
set -e
assert_eq "$LIVE_RC" "1" "live without URL exits 1"

rm -f "$CONFIG"
EMPTY_SUB="$WORKDIR/empty-sub.txt"
: > "$EMPTY_SUB"
set +e
SPUR_MOCK=0 SPUR_SUB_URL="file://${EMPTY_SUB}" PATH="/usr/bin:/bin" fetch_and_render
ZERO_RC=$?
set -e
assert_eq "$ZERO_RC" "1" "live with 0 nodes exits 1"

rm -f "$CONFIG"
SUB="$ROOT/tests/fixtures/vless-reality.txt"
SOCKS_PORT=1191 HTTP_PORT=8229 SPUR_MOCK=0 SPUR_SUB_URL="file://${SUB}" PATH="/usr/bin:/bin" fetch_and_render
assert_eq "$?" "0" "live fetch_and_render with custom ports succeeds"
python3 - "$CONFIG" << 'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
ports = {item["type"]: item["listen_port"] for item in cfg["inbounds"]}
if ports.get("socks") != 1191 or ports.get("http") != 8229:
    raise SystemExit(f"FAIL: live render must use SOCKS_PORT/HTTP_PORT (got {ports})")
PY

# --- a failed render must leave the previous config in place ---
FAILBIN="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" "$FAKEBIN" "$FAILBIN" "$HEALTHF"' EXIT
cat > "$FAILBIN/curl" << 'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$FAILBIN/curl"

assert_config_intact() {
  local msg="$1"
  grep -q 'sentinel-config' "$CONFIG" || {
    echo "FAIL: $msg (config now: $(cat "$CONFIG" 2>/dev/null || echo missing))" >&2
    exit 1
  }
  if [ -e "$CONFIG.tmp" ]; then
    echo "FAIL: $msg left a temp file behind" >&2
    exit 1
  fi
}

printf '%s\n' '{"sentinel-config": true}' > "$CONFIG"
set +e
SPUR_MOCK=0 SPUR_SUB_URL="https://sub.invalid/list" PATH="$FAILBIN:/usr/bin:/bin" fetch_and_render
FETCH_FAIL_RC=$?
set -e
assert_eq "$FETCH_FAIL_RC" "1" "failed subscription fetch exits 1"
assert_config_intact "failed fetch must not truncate the existing config"

set +e
SPUR_MOCK=0 SPUR_SUB_URL="file://${EMPTY_SUB}" PATH="/usr/bin:/bin" fetch_and_render
RENDER_FAIL_RC=$?
set -e
assert_eq "$RENDER_FAIL_RC" "1" "failed render exits 1"
assert_config_intact "failed render must not truncate the existing config"

# --- start_singbox tracks the background pid for SIGHUP refresh ---
SBBIN="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" "$FAKEBIN" "$FAILBIN" "$SBBIN" "$HEALTHF"' EXIT
SB_PIDFILE="$SBBIN/pid"
cat > "$SBBIN/sing-box" << 'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  check) exit 0 ;;
  run)
    echo "$$" > "$SB_PIDFILE"
    exec sleep 0.5
    ;;
esac
exit 1
EOF
chmod +x "$SBBIN/sing-box"

unset SING_BOX_PID
SB_PIDFILE="$SB_PIDFILE" PATH="$SBBIN:/usr/bin:/bin" start_singbox
if [ -z "${SING_BOX_PID:-}" ]; then
  echo "FAIL: start_singbox must set SING_BOX_PID" >&2
  exit 1
fi
waited=0
while [ ! -s "$SB_PIDFILE" ] && [ "$waited" -lt 30 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
assert_eq "$SING_BOX_PID" "$(cat "$SB_PIDFILE" 2>/dev/null || echo missing)" \
  "SING_BOX_PID is the backgrounded sing-box pid"
wait "$SING_BOX_PID" 2>/dev/null || true
