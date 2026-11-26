#!/bin/bash

# StackPilot - Port Utilities
# Finding free ports on the server.
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   source lib/port-utils.sh
#   PORT=$(find_free_port 8000)                 # on the server
#   USED=$(listening_ports vps) && PORT=$(next_free_port 8000 "$USED")

# Load server-exec if not loaded
if ! type is_on_server &>/dev/null; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/server-exec.sh"
fi

# Shell code for the server: installs ss (iproute2) when it is missing and exits 127
# when that fails, so a missing ss never reads as "no port in use".
_SP_ENSURE_SS='if ! command -v ss >/dev/null 2>&1; then
    S=""; [ "$(id -u)" = 0 ] || S=sudo
    if command -v apt-get >/dev/null 2>&1; then $S apt-get update -qq && $S apt-get install -y -qq iproute2
    elif command -v dnf >/dev/null 2>&1; then $S dnf install -y -q iproute
    elif command -v yum >/dev/null 2>&1; then $S yum install -y -q iproute
    elif command -v apk >/dev/null 2>&1; then $S apk add --quiet iproute2
    fi >/dev/null 2>&1
fi
command -v ss >/dev/null 2>&1 || exit 127'

# Shell code for the server: prints "PORT PROGRAM" for each listener on port 80 or 443
# that is not Caddy (Caddy serves the sites on both).
_SP_WEB_PORT_HOLDERS="$_SP_ENSURE_SS"'
S=""; [ "$(id -u)" = 0 ] || S=sudo
$S ss -Hltnp | while read -r _ _ _ local _ users; do
    case "${local##*:}" in 80|443) ;; *) continue ;; esac
    program="${users#*\"}"; program="${program%%\"*}"
    [ "$program" = caddy ] || echo "${local##*:} ${program:-unknown}"
done | sort -u'

# Shell code for the server: prints its listening TCP ports, one per line.
_SP_LISTENING_PORTS="$_SP_ENSURE_SS"'
ss -tln | awk "{print \$4}" | grep -oE "[0-9]+$" | sort -un'

# Listening TCP ports on the server (SSH_ALIAS, or this machine when on the server)
# Arguments: [SSH_ALIAS]
listening_ports() {
    if is_on_server; then
        bash -c "$_SP_LISTENING_PORTS"
    else
        ssh -o ConnectTimeout=5 "${1:-${SSH_ALIAS:-vps}}" "$_SP_LISTENING_PORTS" 2>/dev/null
    fi
}

# Host ports published by the running containers of an installed app (its Compose project)
# Arguments: APP_NAME
app_published_ports() {
    server_exec_timeout 5 "sudo docker ps --filter label=com.docker.compose.project=$1 --format '{{.Ports}}' 2>/dev/null" \
        | grep -oE '[0-9]+->' | tr -d '>-' | sort -un
}

# First port >= BASE_PORT that is not in USED_PORTS (one per line)
# Arguments: BASE_PORT USED_PORTS
next_free_port() {
    local port="$1"
    while grep -qx "$port" <<< "$2"; do
        port=$((port + 1))
    done
    echo "$port"
}

# First free port >= BASE_PORT on this machine (on the server)
# Arguments: BASE_PORT
find_free_port() {
    local used
    used=$(bash -c "$_SP_LISTENING_PORTS") || return 1
    next_free_port "${1:-8000}" "$used"
}

# Read the published host port saved by an installer, with legacy env fallback.
read_existing_app_port() {
    local marker="$1" legacy_env="$2" port
    port=$(server_exec_timeout 5 "if [ -f '$marker' ]; then cat '$marker'; else grep -m1 '^PORT=' '$legacy_env' 2>/dev/null | cut -d= -f2; fi" 2>/dev/null) || return 1
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] || return 1
    printf '%s\n' "$port"
}

# Export functions
export _SP_ENSURE_SS _SP_LISTENING_PORTS _SP_WEB_PORT_HOLDERS
export -f listening_ports app_published_ports next_free_port find_free_port
export -f read_existing_app_port
