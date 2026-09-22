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
  if python3 -c 'import coverage' >/dev/null 2>&1; then
    python3 -m coverage run --source=docker -m unittest -v tests/test_render_config.py
    python3 -m coverage xml -o "$ROOT/coverage.xml"
  else
    python3 -m unittest -v tests/test_render_config.py
  fi
else
  echo "==> skip python unittest (no tests/test_render_config.py yet)"
fi
python3 -m unittest -v tests/test_dispatch_release.py
