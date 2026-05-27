# shellcheck shell=bash
# Linux libsecret backend using secret-tool (libsecret-tools package).

: "${STACKPILOT_LIBSECRET_APP:=stackpilot}"

_backend_id() { printf 'libsecret'; }

_backend_available() {
    command -v secret-tool >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]
}

_backend_set() {
    local name="$1" value="$2"
    printf '%s' "$value" | secret-tool store --label="stackpilot:$name" \
        app "$STACKPILOT_LIBSECRET_APP" key "$name"
}

_backend_get() {
    local name="$1"
    local out
    out=$(secret-tool lookup app "$STACKPILOT_LIBSECRET_APP" key "$name" 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

_backend_has() {
    local name="$1"
    local out
    out=$(secret-tool lookup app "$STACKPILOT_LIBSECRET_APP" key "$name" 2>/dev/null) || return 1
    [ -n "$out" ]
}

_backend_rm() {
    local name="$1"
    secret-tool clear app "$STACKPILOT_LIBSECRET_APP" key "$name" 2>/dev/null || true
    return 0
}

_backend_list() {
    # secret-tool search dumps all matching entries; we extract attribute.key values.
    secret-tool search --all app "$STACKPILOT_LIBSECRET_APP" 2>/dev/null \
        | awk -F' = ' '/^attribute\.key/ { print $2 }'
}
