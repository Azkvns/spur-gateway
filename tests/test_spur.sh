#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/helpers.sh"

SPUR="$ROOT/bin/spur"

if [ ! -f "$SPUR" ]; then
  echo "FAIL: bin/spur not found" >&2
  exit 1
fi

OUT="$(mktemp)"
ERR="$(mktemp)"
ENVF="$(mktemp)"
printf '%s\n' 'SOCKS_PORT=1090' 'HTTP_PORT=8128' > "$ENVF"
trap 'rm -f "$OUT" "$ERR" "$ENVF"' EXIT

run_spur() {
  RUN_RC=0
  "$SPUR" "$@" >"$OUT" 2>"$ERR" || RUN_RC=$?
}

# --- proxy not ready ---
PROXY_READY=0 \
SPUR_GW_DRY_RUN=1 \
SPUR_GW_ENV_FILE="$ENVF" \
run_spur
assert_eq "$RUN_RC" "1" "spur exits 1 when proxy not ready"
assert_eq "$(cat "$ERR")" "spur-gw up first" "proxy not ready message"

# --- dry-run exports proxy env ---
PROXY_READY=1 \
SPUR_GW_DRY_RUN=1 \
SPUR_GW_ENV_FILE="$ENVF" \
run_spur
assert_eq "$RUN_RC" "0" "spur dry-run exit 0"
grep -q '^ALL_PROXY=socks5h://127.0.0.1:1090$' "$OUT" || {
  echo "FAIL: ALL_PROXY not set in dry-run env (got: $(grep ALL_PROXY "$OUT" || echo none))" >&2
  exit 1
}
grep -q '^HTTPS_PROXY=http://127.0.0.1:8128$' "$OUT" || {
  echo "FAIL: HTTPS_PROXY not set in dry-run env" >&2
  exit 1
}
grep -q '^HTTP_PROXY=http://127.0.0.1:8128$' "$OUT" || {
  echo "FAIL: HTTP_PROXY not set in dry-run env" >&2
  exit 1
}
grep -q '^NO_PROXY=localhost,127.0.0.1$' "$OUT" || {
  echo "FAIL: NO_PROXY not set in dry-run env" >&2
  exit 1
}

# --- git/ssh get SOCKS ProxyCommand ---
PROXY_READY=1 \
SPUR_GW_DRY_RUN=1 \
SPUR_GW_ENV_FILE="$ENVF" \
run_spur git
assert_eq "$RUN_RC" "0" "spur git dry-run exit 0"
grep -q "^GIT_SSH_COMMAND=ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:1090 %h %p'\$" "$OUT" || {
  echo "FAIL: spur git must set GIT_SSH_COMMAND with SOCKS ProxyCommand" >&2
  exit 1
}

# --- exec passes through command ---
PROXY_READY=1 \
SPUR_GW_ENV_FILE="$ENVF" \
PATH=/usr/bin:/bin \
run_spur printenv ALL_PROXY
assert_eq "$RUN_RC" "0" "spur exec exit 0"
assert_eq "$(sed -n '1p' "$OUT")" "socks5h://127.0.0.1:1090" "spur exec sets ALL_PROXY for child"

# --- secrets stay out of dry-run stdout and child env ---
SECRETF="$(mktemp)"
printf '%s\n' 'SOCKS_PORT=1090' 'HTTP_PORT=8128' 'SPUR_SUB_URL=s3cret-must-not-leak' > "$SECRETF"
trap 'rm -f "$OUT" "$ERR" "$ENVF" "$SECRETF"' EXIT

PROXY_READY=1 \
SPUR_GW_DRY_RUN=1 \
SPUR_GW_ENV_FILE="$SECRETF" \
run_spur
assert_eq "$RUN_RC" "0" "spur dry-run with secrets in env file exit 0"
grep -q '^ALL_PROXY=socks5h://127.0.0.1:1090$' "$OUT" || {
  echo "FAIL: ALL_PROXY not set in dry-run env after secret strip" >&2
  exit 1
}
if grep -q 's3cret-must-not-leak' "$OUT" "$ERR"; then
  echo "FAIL: SPUR_SUB_URL value leaked into dry-run output" >&2
  exit 1
fi
if grep -q '^SPUR_SUB_URL=' "$OUT"; then
  echo "FAIL: SPUR_SUB_URL present in dry-run env" >&2
  exit 1
fi

PROXY_READY=1 \
SPUR_GW_ENV_FILE="$SECRETF" \
PATH=/usr/bin:/bin \
run_spur sh -c 'printf %s "${SPUR_SUB_URL-UNSET}"'
assert_eq "$RUN_RC" "0" "spur exec without secret in child exit 0"
assert_eq "$(cat "$OUT")" "UNSET" "child does not inherit SPUR_SUB_URL"

# --- only the proxy ports are taken from .env; other keys stay out of the child ---
GATEF="$(mktemp)"
printf '%s\n' \
  'SOCKS_PORT=1090' \
  'HTTP_PORT=8128' \
  'SPUR_PROBE_PRIMARY=https://canary.invalid' \
  'SPUR_HEALTH_INTERVAL=15' > "$GATEF"
trap 'rm -f "$OUT" "$ERR" "$ENVF" "$SECRETF" "$GATEF"' EXIT

PROXY_READY=1 \
SPUR_GW_DRY_RUN=1 \
SPUR_GW_ENV_FILE="$GATEF" \
run_spur
assert_eq "$RUN_RC" "0" "spur dry-run with extra env-file keys exit 0"
grep -q '^ALL_PROXY=socks5h://127.0.0.1:1090$' "$OUT" || {
  echo "FAIL: ports must still be read from the env file" >&2
  exit 1
}
if grep -qE '^(SPUR_PROBE_PRIMARY|SPUR_HEALTH_INTERVAL)=' "$OUT"; then
  echo "FAIL: spur must not export the whole env file into the child" >&2
  exit 1
fi

PROXY_READY=1 \
SPUR_GW_ENV_FILE="$GATEF" \
PATH=/usr/bin:/bin \
run_spur sh -c 'printf %s "${SPUR_PROBE_PRIMARY-UNSET}"'
assert_eq "$RUN_RC" "0" "spur exec with extra env-file keys exit 0"
assert_eq "$(cat "$OUT")" "UNSET" "child does not inherit unrelated env-file keys"
