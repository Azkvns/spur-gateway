#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"

if [ ! -f "$COMPOSE" ]; then
  echo "FAIL: docker-compose.yml not found" >&2
  exit 1
fi

content="$(cat "$COMPOSE")"

if ! grep -q '127.0.0.1:1090:1090' <<< "$content"; then
  echo "FAIL: docker-compose.yml must publish SOCKS on 127.0.0.1:1090:1090" >&2
  exit 1
fi

if ! grep -q '127.0.0.1:8128:8128' <<< "$content"; then
  echo "FAIL: docker-compose.yml must publish HTTP proxy on 127.0.0.1:8128:8128" >&2
  exit 1
fi

if grep -qE '^\s*-\s*"1090:1090"' <<< "$content"; then
  echo "FAIL: docker-compose.yml must not expose SOCKS on all interfaces (bare 1090:1090)" >&2
  exit 1
fi

# Healthcheck: proxy port 1090 open AND /run/spur-gw-health contains state=ok
if ! grep -q 'healthcheck:' <<< "$content"; then
  echo "FAIL: docker-compose.yml must define a healthcheck" >&2
  exit 1
fi

health_block="$(awk '/^[[:space:]]*healthcheck:/{flag=1} flag{print} flag && /^[^[:space:]#]/{if (!/^[[:space:]]*healthcheck:/) exit}' "$COMPOSE")"
if ! grep -q '/run/spur-gw-health' <<< "$health_block"; then
  echo "FAIL: healthcheck must read /run/spur-gw-health" >&2
  exit 1
fi
if ! grep -q 'state=ok' <<< "$health_block"; then
  echo "FAIL: healthcheck must require state=ok in /run/spur-gw-health" >&2
  exit 1
fi
if ! grep -q '1090' <<< "$health_block"; then
  echo "FAIL: healthcheck must check that proxy port 1090 is open" >&2
  exit 1
fi

# Host/stack env must reach the container via `environment:` (Portainer does not inject
# stack vars through env_file alone).
if ! grep -qE 'SPUR_MOCK:[[:space:]]*\$\{SPUR_MOCK:-0\}' <<< "$content"; then
  echo "FAIL: compose must pass \${SPUR_MOCK:-0} into the container environment" >&2
  exit 1
fi
if ! grep -qE 'SPUR_SUB_URL:[[:space:]]*\$\{SPUR_SUB_URL:-\}' <<< "$content"; then
  echo "FAIL: compose must pass \${SPUR_SUB_URL:-} into the container environment" >&2
  exit 1
fi
