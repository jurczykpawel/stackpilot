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
#   cytrus-domain.sh - 3001

set -e

SSH_ALIAS="${1:-vps}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# This script only runs from the local machine
if [ -f /klucz_api ]; then
    echo "This script only runs on the local machine."
    echo "The toolbox is already installed on this server."
    exit 1
fi

echo ""
echo "📦 Installing StackPilot on server"
echo ""
echo "   Server: $SSH_ALIAS"
echo "   Source: $REPO_ROOT"
echo "   Target: /opt/stackpilot/"
echo ""

# Check rsync
if ! command -v rsync &>/dev/null; then
    echo "❌ rsync is not installed"
    echo "   Mac:   brew install rsync"
    echo "   Linux: sudo apt install rsync"
    exit 1
fi

# Copy toolbox to server
echo "🚀 Copying files..."
rsync -az --delete \
    --exclude '.git' \
    --exclude 'node_modules' \
    --exclude 'mcp-server' \
    --exclude '.claude' \
    --exclude '*.md' \
    "$REPO_ROOT/" "$SSH_ALIAS:/opt/stackpilot/"

# Add to PATH — detect shell on the server and use the appropriate file
# zsh: ~/.zshenv (read ALWAYS — interactive, non-interactive, login, non-login)
# bash: ~/.bashrc (read on ssh host "cmd" + interactive)
echo "🔧 Configuring PATH..."
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
echo "✅ Toolbox installed!"
echo ""
echo "Now you can:"
echo "   ssh $SSH_ALIAS"
echo "   deploy.sh uptime-kuma"
echo "   cytrus-domain.sh - 3001"
echo ""
echo "To update: run this script again"
echo ""
