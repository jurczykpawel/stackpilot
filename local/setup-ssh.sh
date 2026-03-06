#!/bin/bash

# StackPilot - SSH Configurator
# Configures SSH connection to a VPS server (key + alias).
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   bash local/setup-ssh.sh
#   bash <(curl -s https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/local/setup-ssh.sh)

# Load i18n (standalone — no lib sourced)
_SSHC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SSHC_DIR/../lib/i18n.sh"
GREEN="${GREEN:-\033[0;32m}"
BLUE="${BLUE:-\033[0;34m}"
YELLOW="${YELLOW:-\033[1;33m}"
RED="${RED:-\033[0;31m}"
NC="${NC:-\033[0m}"

# This script only runs on the local machine (configures SSH TO the server)
if [ -f /opt/stackpilot/.server-marker ]; then
    msg "$MSG_SSHC_LOCAL_ONLY"
    exit 1
fi

clear
msg "$MSG_SSHC_HEADER_LINE"
msg "$MSG_SSHC_HEADER_TITLE"
msg "$MSG_SSHC_HEADER_LINE"
echo ""
msg "$MSG_SSHC_INTRO"
msg "$MSG_SSHC_INTRO2"
msg "$MSG_SSHC_INTRO3"
echo ""
msg "$MSG_SSHC_PREPARE"
echo ""

# 1. Collect data
read -p "$(msg_n "$MSG_SSHC_PROMPT_HOST")" HOST
read -p "$(msg_n "$MSG_SSHC_PROMPT_PORT")" PORT
read -p "$(msg_n "$MSG_SSHC_PROMPT_USER")" USER
USER=${USER:-root}
read -p "$(msg_n "$MSG_SSHC_PROMPT_ALIAS")" ALIAS
ALIAS=${ALIAS:-vps}

if [[ -z "$HOST" || -z "$PORT" ]]; then
    msg "$MSG_SSHC_MISSING"
    exit 1
fi

echo ""

# 2. Generate SSH key (if it doesn't exist)
KEY_PATH="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY_PATH" ]; then
    msg "$MSG_SSHC_KEY_GENERATING"
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "vps_key"
    msg "$MSG_SSHC_KEY_GENERATED"
else
    msg "$MSG_SSHC_KEY_EXISTS"
fi

# 3. Copy key to server
echo ""
msg "$MSG_SSHC_COPY_KEY"
echo ""

ssh-copy-id -i "$KEY_PATH.pub" -p "$PORT" "$USER@$HOST"

if [ $? -ne 0 ]; then
    msg "$MSG_SSHC_COPY_FAIL"
    exit 1
fi

# 4. Configure ~/.ssh/config
CONFIG_FILE="$HOME/.ssh/config"
[ ! -f "$CONFIG_FILE" ] && touch "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE"

if grep -q "^Host $ALIAS$" "$CONFIG_FILE"; then
    msg "$MSG_SSHC_ALIAS_EXISTS" "$ALIAS"
else
    cat >> "$CONFIG_FILE" <<EOF

Host $ALIAS
    HostName $HOST
    Port $PORT
    User $USER
    IdentityFile $KEY_PATH
    ServerAliveInterval 60
EOF
    msg "$MSG_SSHC_ALIAS_ADDED" "$ALIAS"
fi

echo ""
msg "$MSG_SSHC_DONE"
echo ""
msg "$MSG_SSHC_CONNECT" "$ALIAS"
echo ""
