# Provider-agnostic keystore API. Backend is sourced before this file (by detect.sh
# in production, or by mock-backend.sh in tests).

_keystore_valid_name() {
    [[ "$1" =~ ^[a-z][a-z0-9_]*$ ]]
}

keystore_set() {
    local name="${1:-}" value="${2:-}"
    if ! _keystore_valid_name "$name"; then
        echo "keystore: invalid name '$name' (must match [a-z][a-z0-9_]*)" >&2
        return 2
    fi
    if [ -z "$value" ]; then
        echo "keystore: empty value for '$name'" >&2
        return 2
    fi
    if ! _backend_set "$name" "$value"; then
        echo "keystore: backend refused to store '$name'" >&2
        return 5
    fi
    unset "STACKPILOT_KEY_CACHE_$(echo "$name" | tr '[:lower:]' '[:upper:]')"
    return 0
}

keystore_get() {
    local name="${1:-}"
    if ! _keystore_valid_name "$name"; then
        return 1
    fi
    _backend_get "$name"
}

keystore_has() {
    local name="${1:-}"
    _keystore_valid_name "$name" || return 1
    _backend_has "$name"
}

keystore_rm() {
    local name="${1:-}"
    _keystore_valid_name "$name" || return 0
    _backend_rm "$name"
    unset "STACKPILOT_KEY_CACHE_$(echo "$name" | tr '[:lower:]' '[:upper:]')"
    return 0
}

keystore_list() {
    _backend_list
}

keystore_backend() {
    _backend_id
}

keystore_require_keys() {
    local missing=0
    local name
    for name in "$@"; do
        if ! keystore_has "$name"; then
            printf '%s\n' "$name"
            missing=$((missing+1))
        fi
    done
    return $missing
}
