# shellcheck shell=bash
# Picks the right keystore backend at runtime.
# keystore_detect_backend ONLY decides the id; never sources files (it may be
# called via $() which executes in a subshell — any sourcing would not persist).
# keystore_load_backend does the actual sourcing in the caller's shell.

_KEYSTORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Probe backend availability WITHOUT sourcing. Returns 0 if id is usable.
_keystore_backend_probe() {
    case "$1" in
        keychain)
            [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1
            ;;
        libsecret)
            command -v secret-tool >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]
            ;;
        file)
            [ -n "${HOME:-}" ]
            ;;
        *)
            return 1
            ;;
    esac
}

# Print backend id to stdout. Exit 1 on error. Safe to call from $().
keystore_detect_backend() {
    local override="${STACKPILOT_KEYSTORE:-}"
    if [ -n "$override" ]; then
        case "$override" in
            keychain|libsecret|file) ;;
            *)
                echo "stackpilot keystore: unknown backend '$override' (valid: keychain|libsecret|file)" >&2
                return 1
                ;;
        esac
        if _keystore_backend_probe "$override"; then
            printf '%s' "$override"
            return 0
        fi
        echo "stackpilot keystore: backend '$override' not available on this system" >&2
        return 1
    fi

    if _keystore_backend_probe keychain; then printf 'keychain'; return 0; fi
    if _keystore_backend_probe libsecret; then printf 'libsecret'; return 0; fi
    if _keystore_backend_probe file; then printf 'file'; return 0; fi
    echo "stackpilot keystore: no backend available" >&2
    return 1
}

# Source the right backend file in the CALLER's shell. Idempotent.
keystore_load_backend() {
    local id
    id=$(keystore_detect_backend) || return 1
    # shellcheck source=/dev/null
    source "$_KEYSTORE_DIR/backend-$id.sh"
    export STACKPILOT_KEYSTORE_ACTIVE="$id"
}
