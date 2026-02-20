#!/bin/bash

# StackPilot - LittleLink
# Link-in-bio page (Linktree alternative).
# Uses Caddy file_server mode (static files).
# Author: Pawel (Lazy Engineer)

set -e

APP_NAME="littlelink"
echo "--- LittleLink Setup ---"

# Required: DOMAIN
if [ -z "$DOMAIN" ]; then
    echo "Missing required variable: DOMAIN"
    echo "   Usage: DOMAIN=bio.example.com ./install.sh"
    exit 1
fi
echo "Domain: $DOMAIN"

# Prerequisites
if ! command -v git &> /dev/null; then
    echo "Installing git..."
    sudo apt update && sudo apt install -y git
fi

# Caddy file_server mode
echo "Mode: Caddy file_server"

if ! command -v caddy &> /dev/null; then
    echo "Caddy not installed. Run system/caddy-install.sh"
    exit 1
fi

WEB_ROOT="/var/www/$APP_NAME"

# Download LittleLink
sudo mkdir -p "$WEB_ROOT"
if [ -d "$WEB_ROOT/.git" ] || [ -f "$WEB_ROOT/index.html" ]; then
    echo "LittleLink already installed. Skipping download."
else
    sudo git clone --depth 1 https://github.com/sethcottle/littlelink.git "$WEB_ROOT"
    sudo rm -rf "$WEB_ROOT/.git"
fi

# Caddy will be configured by sp-expose (called from deploy.sh)
# Just store the path for later
echo "$WEB_ROOT" > /tmp/littlelink_webroot

echo ""
echo "LittleLink installed!"
echo "   Files: $WEB_ROOT"
echo ""
echo "Edit: nano $WEB_ROOT/index.html"
