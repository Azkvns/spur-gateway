#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
shopt -s nullglob
tests=("$ROOT"/tests/test_*.sh)
if [ "${#tests[@]}" -eq 0 ]; then
  echo "no bash tests yet"
else
  for test in "${tests[@]}"; do
    echo "==> $(basename "$test")"
    bash "$test"
  done
fi
cd "$ROOT"
if [ -f "$ROOT/tests/test_render_config.py" ]; then
  python3 -m unittest -v tests/test_render_config.py
else
  echo "==> skip python unittest (no tests/test_render_config.py yet)"
fi
