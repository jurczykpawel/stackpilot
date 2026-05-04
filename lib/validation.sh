#!/bin/bash

# StackPilot - Shared input validation helpers.

sp_validate_ssh_alias() {
    local value="$1"
    if ! [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        echo "Invalid SSH alias: $value" >&2
        return 1
    fi
}

sp_validate_domain() {
    local value="$1"
    if ! [[ "$value" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || [[ "$value" == *..* ]]; then
        echo "Invalid domain: $value" >&2
        return 1
    fi
}

sp_validate_absolute_path() {
    local value="$1"
    if ! [[ "$value" =~ ^/[a-zA-Z0-9/_.-]+$ ]]; then
        echo "Invalid path: $value" >&2
        echo "Use an absolute path with letters, numbers, dots, underscores, dashes, and slashes only." >&2
        return 1
    fi
}

sp_validate_redirect_path() {
    local value="$1"
    if ! [[ "$value" =~ ^/[a-zA-Z0-9/_.-]*$ ]]; then
        echo "Invalid redirect path: $value" >&2
        return 1
    fi
}

sp_validate_url() {
    local value="$1"
    if ! [[ "$value" =~ ^https?://[a-zA-Z0-9._/?\&=#:%+-]+$ ]]; then
        echo "Invalid target URL: $value" >&2
        return 1
    fi
}

sp_validate_redirect_code_flag() {
    local value="$1"
    case "$value" in
        ""|--code=301|--code=302) return 0 ;;
        *)
            echo "Invalid redirect code flag: $value (expected --code=301 or --code=302)" >&2
            return 1
            ;;
    esac
}
