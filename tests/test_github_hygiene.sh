#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT/.github/workflows/test.yml" "$ROOT/.github/dependabot.yml" <<'PY'
import pathlib
import sys

workflow = pathlib.Path(sys.argv[1])
dependabot = pathlib.Path(sys.argv[2])

lines = workflow.read_text().splitlines()
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

if not dependabot.is_file():
    sys.exit(f"missing {dependabot}")
text = dependabot.read_text()
for needle in (
    "version: 2",
    "package-ecosystem: github-actions",
    "package-ecosystem: pip",
    "directory: /",
    "interval: weekly",
):
    if needle not in text:
        sys.exit(f"dependabot.yml missing {needle!r}")
if text.count("interval: weekly") != 2:
    sys.exit("dependabot.yml must schedule exactly two weekly updates")
print("ok test workflow permissions")
print("ok dependabot config")
PY
