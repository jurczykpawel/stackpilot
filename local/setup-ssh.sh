#!/bin/bash

# StackPilot - SSH Configurator
# Configures SSH connection to a VPS server (key + alias).
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   bash local/setup-ssh.sh
#   bash <(curl -s https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/local/setup-ssh.sh)

# This script only runs on the local machine (configures SSH TO the server)
if [ -f /klucz_api ]; then
    echo "This script only runs on the local machine (not on the server)."
    exit 1
fi

GREEN='\x1b[0;32m'
BLUE='\x1b[0;34m'
YELLOW='\x1b[1;33m'
RED='\x1b[0;31m'
NC='\x1b[0m'

clear
echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}   🚀 SSH CONFIGURATOR                           ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""
echo -e "This script will configure the SSH connection to your server,"
echo -e "so you can connect by simply typing: ${GREEN}ssh vps${NC}"
echo -e "(no password needed each time!)"
echo ""
echo -e "${YELLOW}Prepare the server details (Host, Port, Password).${NC}"
echo ""

# 1. Collect data
read -p "Enter hostname (e.g. srv20.example.com): " HOST
read -p "Enter SSH port number (e.g. 10107): " PORT
read -p "Enter username (default: root): " USER
USER=${USER:-root}
read -p "SSH alias - what do you want to call this server? (default: vps): " ALIAS
ALIAS=${ALIAS:-vps}

if [[ -z "$HOST" || -z "$PORT" ]]; then
    echo -e "${RED}Error: Host and Port are required!${NC}"
    exit 1
fi

echo ""

# 2. Generate SSH key (if it doesn't exist)
KEY_PATH="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY_PATH" ]; then
    echo -e "${YELLOW}Generating new SSH key (Ed25519)...${NC}"
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "vps_key"
    echo -e "${GREEN}✅ Key generated.${NC}"
else
    echo -e "${GREEN}✅ SSH key already exists.${NC}"
fi

# 3. Copy key to server
echo ""
echo -e "${YELLOW}Now enter the server password (one-time):${NC}"
echo ""

ssh-copy-id -i "$KEY_PATH.pub" -p "$PORT" "$USER@$HOST"

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Error sending key. Check the password and try again.${NC}"
    exit 1
fi

# 4. Configure ~/.ssh/config
CONFIG_FILE="$HOME/.ssh/config"
[ ! -f "$CONFIG_FILE" ] && touch "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE"

if grep -q "^Host $ALIAS$" "$CONFIG_FILE"; then
    echo -e "${YELLOW}Alias '$ALIAS' already exists in ~/.ssh/config. Skipping.${NC}"
else
    cat >> "$CONFIG_FILE" <<EOF

Host $ALIAS
    HostName $HOST
    Port $PORT
    User $USER
    IdentityFile $KEY_PATH
    ServerAliveInterval 60
EOF
    echo -e "${GREEN}✅ Added alias '$ALIAS' to ~/.ssh/config${NC}"
fi

echo ""
echo -e "${GREEN}✅ Done! Connect by typing:${NC}"
echo ""
echo -e "   ${GREEN}ssh $ALIAS${NC}"
echo ""
