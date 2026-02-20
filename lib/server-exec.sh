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

# Ensure toolbox is installed on the server
# Usage: ensure_toolbox [ssh_alias]
ensure_toolbox() {
    local ALIAS="${1:-${SSH_ALIAS:-vps}}"

    # On server — toolbox is already here
    if is_on_server; then
        return 0
    fi

    # Check if sp-expose exists (toolbox marker)
    if server_exec "test -f /opt/stackpilot/local/deploy.sh" 2>/dev/null; then
        return 0
    fi

    echo "Installing toolbox on server..."

    # Use rsync if we have local repo, otherwise git clone
    local SCRIPT_DIR_SE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local REPO_ROOT_SE="$(cd "$SCRIPT_DIR_SE/.." && pwd)"

    if [ -f "$REPO_ROOT_SE/local/deploy.sh" ] && command -v rsync &>/dev/null; then
        rsync -az --delete \
            --exclude '.git' \
            --exclude 'node_modules' \
            --exclude 'mcp-server' \
            --exclude '.claude' \
            --exclude '*.md' \
            "$REPO_ROOT_SE/" "$ALIAS:/opt/stackpilot/" 2>/dev/null
    else
        server_exec "command -v git >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq git >/dev/null 2>&1) && rm -rf /opt/stackpilot && git clone --depth 1 https://github.com/jurczykpawel/stackpilot.git /opt/stackpilot 2>&1"
    fi

    # Add to PATH
    server_exec "grep -q 'stackpilot/local' ~/.bashrc 2>/dev/null || sed -i '1i\\# StackPilot\nexport PATH=/opt/stackpilot/local:\$PATH\n' ~/.bashrc 2>/dev/null; grep -q 'stackpilot/local' ~/.zshenv 2>/dev/null || (echo '' >> ~/.zshenv && echo '# StackPilot' >> ~/.zshenv && echo 'export PATH=/opt/stackpilot/local:\$PATH' >> ~/.zshenv) 2>/dev/null" || true

    # Verification
    if server_exec "test -f /opt/stackpilot/local/deploy.sh" 2>/dev/null; then
        echo -e "${GREEN:-}Toolbox installed${NC:-}"
        return 0
    else
        echo -e "${RED:-}Failed to install toolbox${NC:-}"
        return 1
    fi
}

export _ON_SERVER
export -f is_on_server server_exec server_exec_tty server_exec_timeout
export -f server_copy server_pipe_to server_hostname server_user ensure_toolbox
