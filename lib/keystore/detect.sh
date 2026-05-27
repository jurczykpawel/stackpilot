# Picks the right keystore backend at runtime.
# Sourcing this file defines keystore_detect_backend and keystore_load_backend.

_KEYSTORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print backend id to stdout. Exit 1 on error.
keystore_detect_backend() {
    local override="${STACKPILOT_KEYSTORE:-}"
    if [ -n "$override" ]; then
        case "$override" in
            keychain|libsecret|file)
                # shellcheck source=/dev/null
                source "$_KEYSTORE_DIR/backend-$override.sh"
                if _backend_available; then
                    printf '%s' "$override"
                    return 0
                else
                    echo "stackpilot keystore: backend '$override' not available on this system" >&2
                    return 1
                fi
                ;;
            *)
                echo "stackpilot keystore: unknown backend '$override' (valid: keychain|libsecret|file)" >&2
                return 1
                ;;
        esac
    fi

    if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "$_KEYSTORE_DIR/backend-keychain.sh"
        if _backend_available; then printf 'keychain'; return 0; fi
    fi
    if [ "$(uname -s)" = "Linux" ] && command -v secret-tool >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        # shellcheck source=/dev/null
        source "$_KEYSTORE_DIR/backend-libsecret.sh"
        if _backend_available; then printf 'libsecret'; return 0; fi
    fi
    # shellcheck source=/dev/null
    source "$_KEYSTORE_DIR/backend-file.sh"
    printf 'file'
    return 0
}

# Source the right backend file once. Idempotent.
keystore_load_backend() {
    if [ -n "${STACKPILOT_KEYSTORE_ACTIVE:-}" ]; then
        return 0
    fi
    local id
    id=$(keystore_detect_backend) || return 1
    export STACKPILOT_KEYSTORE_ACTIVE="$id"
}
