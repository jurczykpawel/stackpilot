#!/bin/bash

# StackPilot - read values an earlier installation wrote, so a re-install keeps them.
# deploy.sh passes this file's directory to installers as STACKPILOT_LIB.
#
# Usage (in apps/<app>/install.sh):
#   source "${STACKPILOT_LIB:-/opt/stackpilot/lib}/stack-config.sh"
#   SECRET=$(stack_value "$STACK_DIR/.env" SECRET || openssl rand -hex 32)

# stack_value FILE KEY — prints KEY's value from FILE (KEY=value, "- KEY=value" or
# "KEY: value", optionally quoted); returns 1 when FILE or KEY is missing or empty.
stack_value() {
    local file="$1" key="$2" value
    sudo test -f "$file" 2>/dev/null || return 1
    value=$(sudo awk -v key="$key" '
        { line = $0; sub(/^[ \t]*(-[ \t]*)?/, "", line) }
        index(line, key "=") == 1 || index(line, key ":") == 1 {
            value = substr(line, length(key) + 2)
            sub(/^[ \t]+/, "", value); sub(/[ \t\r]+$/, "", value)
            if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
            print value; exit
        }' "$file")
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}
