#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

tracked="$(git -C "$ROOT" ls-files -- docs/superpowers)"
if [ -n "$tracked" ]; then
  printf 'tracked docs/superpowers files:\n%s\n' "$tracked" >&2
  exit 1
fi

python3 - \
  "$ROOT/.github/workflows/test.yml" \
  "$ROOT/.github/dependabot.yml" \
  "$ROOT/README.md" \
  "$ROOT/.gitignore" \
  "$ROOT/mkdocs.yml" <<'PY'
import pathlib
import sys

workflow = pathlib.Path(sys.argv[1])
dependabot = pathlib.Path(sys.argv[2])
readme = pathlib.Path(sys.argv[3])
gitignore = pathlib.Path(sys.argv[4])
mkdocs = pathlib.Path(sys.argv[5])

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

section = readme.read_text()
start = section.find("## CI and releases")
end = section.find("\n## ", start + 1)
if start < 0 or end < 0:
    sys.exit("README is missing the CI and releases section")
ci = section[start:end]
for needle in (
    "Same-repo PRs squash-merge after green checks; the head branch is deleted.",
    "Fork PRs are never auto-merged.",
    "Merge commits and rebase merges are disabled.",
    "Tags matching `v*` cannot be moved or deleted.",
    "Dependabot opens weekly updates for GitHub Actions and `requirements-docs.txt`.",
):
    if needle not in ci:
        sys.exit(f"README CI section missing {needle!r}")

ignore_lines = gitignore.read_text().splitlines()
if "docs/superpowers/" not in ignore_lines:
    sys.exit("gitignore missing docs/superpowers/")

mkdocs_text = mkdocs.read_text()
if "exclude_docs:" not in mkdocs_text or "/superpowers/" not in mkdocs_text:
    sys.exit("mkdocs.yml must exclude /superpowers/")

print("ok test workflow permissions")
print("ok dependabot config")
print("ok readme ci policy")
print("ok docs superpowers excluded")
PY
