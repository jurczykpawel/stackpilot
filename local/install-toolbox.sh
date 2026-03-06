#!/bin/bash

# StackPilot - Install Toolbox on Server
# Copies the toolbox to the server so scripts can run directly.
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/install-toolbox.sh [ssh_alias]
#
# After installation on the server:
#   ssh vps
#   deploy.sh uptime-kuma
#   sp-expose app.example.com 3001

set -e

SSH_ALIAS="${1:-vps}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load i18n
_ITB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ITB_DIR/../lib/i18n.sh"
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
NC="${NC:-\033[0m}"

# This script only runs from the local machine
if [ -f /opt/stackpilot/.server-marker ]; then
    msg "$MSG_TB_LOCAL_ONLY"
    msg "$MSG_TB_ALREADY_INSTALLED"
    exit 1
fi

echo ""
msg "$MSG_TB_HEADER"
echo ""
msg "$MSG_TB_SERVER" "$SSH_ALIAS"
msg "$MSG_TB_SOURCE" "$REPO_ROOT"
msg "$MSG_TB_TARGET"
echo ""

# Check rsync
if ! command -v rsync &>/dev/null; then
    msg "$MSG_TB_NO_RSYNC"
    msg "$MSG_TB_NO_RSYNC_MAC"
    msg "$MSG_TB_NO_RSYNC_LINUX"
    exit 1
fi

# Copy toolbox to server
msg "$MSG_TB_COPYING"
rsync -az --delete \
    --exclude '.git' \
    --exclude 'node_modules' \
    --exclude 'mcp-server' \
    --exclude '.claude' \
    --exclude '*.md' \
    "$REPO_ROOT/" "$SSH_ALIAS:/opt/stackpilot/"

# Create server marker file (used by server-exec.sh to detect server environment)
ssh "$SSH_ALIAS" "touch /opt/stackpilot/.server-marker"

# Add to PATH — detect shell on the server and use the appropriate file
# zsh: ~/.zshenv (read ALWAYS — interactive, non-interactive, login, non-login)
# bash: ~/.bashrc (read on ssh host "cmd" + interactive)
msg "$MSG_TB_CONFIG_PATH"
TOOLBOX_LINE='export PATH=/opt/stackpilot/local:$PATH'
ssh "$SSH_ALIAS" "
    REMOTE_SHELL=\$(basename \"\$SHELL\" 2>/dev/null)

    # zsh → ~/.zshenv
    if [ \"\$REMOTE_SHELL\" = 'zsh' ]; then
        if ! grep -q 'stackpilot/local' ~/.zshenv 2>/dev/null; then
            echo '' >> ~/.zshenv
            echo '# StackPilot' >> ~/.zshenv
            echo '$TOOLBOX_LINE' >> ~/.zshenv
        fi
    fi

    # bash → ~/.bashrc (at the beginning, before the interactive guard)
    if [ -f ~/.bashrc ]; then
        if ! grep -q 'stackpilot/local' ~/.bashrc 2>/dev/null; then
            sed -i '1i\\# StackPilot\nexport PATH=/opt/stackpilot/local:\$PATH\n' ~/.bashrc
        fi
    fi

    # Clean up old entries from .profile
    if grep -q 'stackpilot/local' ~/.profile 2>/dev/null; then
        sed -i '/# StackPilot/d; /stackpilot\/local/d' ~/.profile
    fi
"

echo ""
msg "$MSG_TB_DONE"
echo ""
msg "$MSG_TB_NOW_YOU_CAN"
msg "$MSG_TB_CMD_SSH" "$SSH_ALIAS"
msg "$MSG_TB_CMD_DEPLOY"
msg "$MSG_TB_CMD_EXPOSE"
echo ""
msg "$MSG_TB_UPDATE"
echo ""
