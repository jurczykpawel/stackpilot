#!/bin/bash

# StackPilot - Server Execution Abstraction
# Transparently runs commands locally or via SSH.
#
# Detection: /opt/stackpilot/.server-marker exists ONLY on servers.
# On local machine -> ssh, scp (as before).
# On server -> bash -c, cp (directly, without SSH).
#
# Usage:
#   source "$SCRIPT_DIR/../lib/server-exec.sh"
#   server_exec "hostname"
#   server_exec_tty "bash install.sh"
#   server_copy "/tmp/file" "/opt/dest"

# Environment detection
if [ -f /opt/stackpilot/.server-marker ]; then
    _ON_SERVER=true
else
    _ON_SERVER=false
fi

# Is the script running on the server?
is_on_server() { [ "$_ON_SERVER" = true ]; }

# Run a command on the server
# Usage: server_exec "command"
server_exec() {
    if is_on_server; then
        bash -c "$1"
    else
        ssh "${SSH_ALIAS:-vps}" "$1"
    fi
}

# Run a command with TTY allocation (for interactive commands)
# Usage: server_exec_tty "command"
server_exec_tty() {
    if is_on_server; then
        bash -c "$1"
    else
        ssh -t "${SSH_ALIAS:-vps}" "$1"
    fi
}

# Run a command with connection timeout
# Usage: server_exec_timeout SECONDS "command"
server_exec_timeout() {
    local timeout="$1"
    local cmd="$2"
    if is_on_server; then
        bash -c "$cmd"
    else
        ssh -o "ConnectTimeout=$timeout" "${SSH_ALIAS:-vps}" "$cmd" 2>/dev/null
    fi
}

# Copy a file TO the server
# Usage: server_copy LOCAL_PATH REMOTE_PATH
server_copy() {
    local src="$1"
    local dst="$2"
    if is_on_server; then
        cp "$src" "$dst"
    else
        scp -q "$src" "${SSH_ALIAS:-vps}:$dst"
    fi
}

# Pipe a file to the server (equivalent: cat FILE | ssh "cat > DEST")
# Usage: server_pipe_to LOCAL_FILE REMOTE_PATH
server_pipe_to() {
    local src="$1"
    local dst="$2"
    if is_on_server; then
        cp "$src" "$dst"
        chmod +x "$dst" 2>/dev/null || true
    else
        cat "$src" | ssh "${SSH_ALIAS:-vps}" "cat > '$dst' && chmod +x '$dst'"
    fi
}

# Get server hostname
# Usage: HOSTNAME=$(server_hostname)
server_hostname() {
    if is_on_server; then
        hostname
    else
        ssh -G "${SSH_ALIAS:-vps}" 2>/dev/null | grep "^hostname " | cut -d' ' -f2
    fi
}

# Get username on the server
# Usage: USER=$(server_user)
server_user() {
    if is_on_server; then
        whoami
    else
        ssh -G "${SSH_ALIAS:-vps}" 2>/dev/null | grep "^user " | cut -d' ' -f2
    fi
}

export _ON_SERVER
export -f is_on_server server_exec server_exec_tty server_exec_timeout
export -f server_copy server_pipe_to server_hostname server_user
