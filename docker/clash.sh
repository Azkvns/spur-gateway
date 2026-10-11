#!/usr/bin/env bash

_clash_base() {
  echo "${SPUR_CLASH_API:-127.0.0.1:9090}"
}

_clash_urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

clash_current() {
  local base json
  base="$(_clash_base)"
  json="$(curl -fsS "http://${base}/proxies/proxy")"
  python3 -c 'import json,sys; print(json.load(sys.stdin)["now"])' <<< "$json"
}

clash_members() {
  local base json
  base="$(_clash_base)"
  json="$(curl -fsS "http://${base}/proxies/proxy")"
  python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["all"]))' <<< "$json"
}

clash_switch() {
  local tag="$1"
  local base
  base="$(_clash_base)"
  curl -fsS -X PUT "http://${base}/proxies/proxy" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${tag}\"}"
}

clash_delay() {
  local tag="$1"
  local base encoded url json delay
  base="$(_clash_base)"
  encoded="$(_clash_urlencode "$tag")"
  url="http://${base}/proxies/${encoded}/delay?url=https://www.gstatic.com/generate_204&timeout=5000"
  json="$(curl -fsS "$url" 2>/dev/null)" || {
    echo 0
    return 0
  }
  delay="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("delay", 0))' <<< "$json" 2>/dev/null)" || {
    echo 0
    return 0
  }
  echo "${delay:-0}"
}

clash_connection_count() {
  local base json
  base="$(_clash_base)"
  json="$(curl -fsS "http://${base}/connections")" || return 1
  python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("connections") or []))' <<< "$json"
}

clash_close_tag() {
  local tag="$1" base json cid encoded
  [ -n "$tag" ] || return 0
  [ "$tag" != "proxy" ] || return 0
  base="$(_clash_base)"
  json="$(curl -fsS "http://${base}/connections" 2>/dev/null)" || return 0
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    encoded="$(_clash_urlencode "$cid")"
    curl -fsS -X DELETE "http://${base}/connections/${encoded}" >/dev/null 2>&1 || true
  done <<EOF
$(SPUR_CLOSE_TAG="$tag" python3 -c '
import json, os, sys
tag = os.environ["SPUR_CLOSE_TAG"]
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for conn in data.get("connections") or []:
    chains = conn.get("chains") or []
    cid = conn.get("id") or ""
    if cid and tag in chains:
        print(cid)
' <<< "$json")
EOF
  return 0
}
