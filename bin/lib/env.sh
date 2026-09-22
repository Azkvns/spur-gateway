load_env() {
  local path="$1"
  local line key value

  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    if [ "${#value}" -ge 2 ]; then
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
      esac
    fi
    export "$key=$value"
  done < "$path"
}

require_env() {
  local path="${1:-}"

  if [ -n "$path" ]; then
    load_env "$path"
  fi

  if [ "${SPUR_MOCK:-0}" = "1" ]; then
    return 0
  fi

  [ -n "${SPUR_SUB_URL:-}" ] || return 1
}
