#!/bin/bash

# StackPilot - Port Utilities
# Finding free ports on the server.
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   source lib/port-utils.sh
#   PORT=$(find_free_port 8000)           # locally
#   PORT=$(find_free_port_remote vps 8000)  # remotely via SSH

# Load server-exec if not loaded
if ! type is_on_server &>/dev/null; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/server-exec.sh"
fi

# Find first free port >= BASE_PORT (locally)
# Single ss call, then searching in memory - no retry limit.
# Arguments: BASE_PORT
# Returns: free port number (stdout)
find_free_port() {
    local port="${1:-8000}"
    local used
    used=$(ss -tlnp 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)

    while echo "$used" | grep -qx "$port"; do
        port=$((port + 1))
    done
    echo "$port"
}

# Find first free port >= BASE_PORT (remotely via SSH)
# Single SSH call, then local searching.
# On server: delegates to find_free_port() (without SSH).
# Arguments: SSH_ALIAS BASE_PORT
# Returns: free port number (stdout)
find_free_port_remote() {
    local ssh_alias="$1"
    local port="${2:-8000}"

    # On server: we don't need SSH
    if is_on_server; then
        find_free_port "$port"
        return
    fi

    local used
    used=$(ssh -o ConnectTimeout=5 "$ssh_alias" "ss -tlnp 2>/dev/null" 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)

    while echo "$used" | grep -qx "$port"; do
        port=$((port + 1))
    done
    echo "$port"
}

# Export functions
export -f find_free_port
export -f find_free_port_remote
