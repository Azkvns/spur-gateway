#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/helpers.sh"
. "$ROOT/bin/lib/env.sh"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

unset SPUR_SUB_URL SPUR_MOCK
printf '%s\n' 'SPUR_SUB_URL=https://example.test/sub' 'SPUR_MOCK=0' > "$tmp"
assert_ok require_env "$tmp"

unset SPUR_SUB_URL SPUR_MOCK
printf '%s\n' 'SPUR_MOCK=0' > "$tmp"
assert_fail require_env "$tmp"

unset SPUR_SUB_URL SPUR_MOCK
printf '%s\n' 'SPUR_MOCK=1' > "$tmp"
assert_ok require_env "$tmp"

unset SPUR_SUB_URL
printf '%s\n' 'SPUR_SUB_URL="https://ex.test/a b"' > "$tmp"
assert_ok load_env "$tmp"
assert_eq "${SPUR_SUB_URL}" 'https://ex.test/a b' "load_env strips matching double quotes"
