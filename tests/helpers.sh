assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [ "$got" != "$want" ]; then
    echo "FAIL: $msg (got='$got' want='$want')" >&2
    exit 1
  fi
}

assert_ok() {
  if ! "$@"; then
    echo "FAIL: expected success: $*" >&2
    exit 1
  fi
}

assert_fail() {
  if "$@"; then
    echo "FAIL: expected failure: $*" >&2
    exit 1
  fi
}
