#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT/.github/workflows/test.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
perm = None
for i, line in enumerate(lines):
    if line.startswith("permissions:"):
        perm = i
        break
    if line.startswith("jobs:"):
        sys.exit("workflow permissions block must appear before jobs:")
if perm is None:
    sys.exit("missing top-level permissions:")
body = []
for line in lines[perm + 1 :]:
    if line and not line.startswith((" ", "\t")):
        break
    body.append(line)
got = [line for line in body if line.strip() and not line.strip().startswith("#")]
if got != ["  contents: read"]:
    sys.exit(f"permissions must be exactly '  contents: read', got {got}")
print("ok test workflow permissions")
PY
