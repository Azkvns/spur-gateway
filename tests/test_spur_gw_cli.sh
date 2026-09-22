#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/helpers.sh"
GW="$ROOT/bin/spur-gw"
OUT="$(mktemp)"; ERR="$(mktemp)"; ENVF="$(mktemp)"
printf '%s\n' 'SPUR_MOCK=1' > "$ENVF"
trap 'rm -f "$OUT" "$ERR" "$ENVF"' EXIT
run_gw() { RUN_RC=0; "$GW" "$@" >"$OUT" 2>"$ERR" || RUN_RC=$?; }

run_gw
assert_eq "$RUN_RC" "2" "no-args exit 2"
assert_eq "$(cat "$ERR")" "usage: spur-gw up|down|status" "no-args usage"

SPUR_GW_DRY_RUN=1 SPUR_GW_ENV_FILE="$ENVF" PATH=/usr/bin:/bin run_gw up
assert_eq "$RUN_RC" "0" "up dry-run"
assert_eq "$(cat "$OUT")" "would up" "up dry-run stdout"

COMPOSE_RUNNING=0 PATH=/usr/bin:/bin run_gw status
assert_eq "$(sed -n '1p' "$OUT")" "compose=stopped" "status stopped"

HEALTHF="$(mktemp)"
printf 'state=ok\nreason=\nserver=nl-1\nupdated=2026-09-11T00:00:00Z\n' > "$HEALTHF"
COMPOSE_RUNNING=1 SPUR_GW_DRY_RUN=1 SPUR_HEALTH_FILE="$HEALTHF" PATH=/usr/bin:/bin run_gw status
assert_eq "$(grep -E '^health=' "$OUT" | cut -d= -f2)" "ok" "status health"
rm -f "$HEALTHF"

printf '%s\n' 'SPUR_MOCK=0' > "$ENVF"
SPUR_GW_DRY_RUN=1 SPUR_GW_ENV_FILE="$ENVF" PATH=/usr/bin:/bin run_gw up
assert_eq "$RUN_RC" "1" "live up without sub url fails"

SPUR_MOCK=1 SPUR_GW_DRY_RUN=1 SPUR_GW_ENV_FILE="$ENVF" PATH=/usr/bin:/bin run_gw up
assert_eq "$RUN_RC" "0" "host mock overrides env file"
assert_eq "$(cat "$OUT")" "would up" "host mock override stdout"
