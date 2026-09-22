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
