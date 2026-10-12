#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/helpers.sh
. "$ROOT/tests/helpers.sh"

CLASH="$ROOT/docker/clash.sh"

if [ ! -f "$CLASH" ]; then
  echo "FAIL: docker/clash.sh not found" >&2
  exit 1
fi

FAKEBIN="$(mktemp -d)"
CURL_LOG="$(mktemp)"
trap 'rm -rf "$FAKEBIN" "$CURL_LOG"' EXIT

cat > "$FAKEBIN/curl" << 'EOF'
#!/usr/bin/env bash
method=GET
url=""
body=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "$a" in
    -X)
      i=$((i + 1))
      method="${args[$i]}"
      ;;
    -d)
      i=$((i + 1))
      body="${args[$i]}"
      ;;
    http://*|https://*)
      url="$a"
      ;;
  esac
  i=$((i + 1))
done
printf 'method=%s url=%s body=%s\n' "$method" "$url" "$body" >> "${CURL_LOG:?}"

case "$url" in
  */proxies/proxy)
    if [ "$method" = PUT ]; then
      exit 0
    fi
    echo '{"now":"nl-1","all":["nl-1","us-1"]}'
    ;;
  */proxies/nl-1/delay*)
    echo '{"delay":142}'
    ;;
  */proxies/bad-node/delay*)
    exit 1
    ;;
  */connections)
    if [ "$method" = DELETE ]; then
      exit 0
    fi
    echo '{"connections":[{"id":"c-old","chains":["nl-1","proxy"]},{"id":"c-new","chains":["us-1","proxy"]}]}'
    ;;
  *)
    echo "unexpected url: $url" >&2
    exit 22
    ;;
esac
EOF
chmod +x "$FAKEBIN/curl"

export CURL_LOG
export PATH="$FAKEBIN:$PATH"
# shellcheck source=docker/clash.sh
. "$CLASH"

CUR="$(clash_current)"
assert_eq "$CUR" "nl-1" "clash_current returns .now from GET /proxies/proxy"

MEMBERS="$(clash_members)"
assert_eq "$MEMBERS" $'nl-1\nus-1' "clash_members returns group names one per line"

clash_switch us-1
grep -q 'method=PUT url=http://127.0.0.1:9090/proxies/proxy body={"name":"us-1"}' "$CURL_LOG" || {
  echo "FAIL: clash_switch must PUT /proxies/proxy with body {\"name\":\"us-1\"} (log: $(cat "$CURL_LOG"))" >&2
  exit 1
}

DELAY="$(clash_delay nl-1)"
assert_eq "$DELAY" "142" "clash_delay returns delay ms from API"

DELAY_FAIL="$(clash_delay bad-node)"
assert_eq "$DELAY_FAIL" "0" "clash_delay returns 0 on curl error"

COUNT="$(clash_connection_count)"
assert_eq "$COUNT" "2" "clash_connection_count returns connections length"

: > "$CURL_LOG"
clash_close_tag nl-1
grep -q 'method=DELETE url=http://127.0.0.1:9090/connections/c-old' "$CURL_LOG" || {
  echo "FAIL: clash_close_tag must DELETE only the matching id (log: $(cat "$CURL_LOG"))" >&2
  exit 1
}
if grep -q 'connections/c-new' "$CURL_LOG"; then
  echo "FAIL: clash_close_tag closed a connection for another tag" >&2
  exit 1
fi

export SPUR_CLASH_API="10.0.0.5:19090"
: > "$CURL_LOG"
CUR_CUSTOM="$(clash_current)"
assert_eq "$CUR_CUSTOM" "nl-1" "clash_current uses SPUR_CLASH_API"
grep -q 'url=http://10.0.0.5:19090/proxies/proxy' "$CURL_LOG" || {
  echo "FAIL: clash_current must call SPUR_CLASH_API host (log: $(cat "$CURL_LOG"))" >&2
  exit 1
}
