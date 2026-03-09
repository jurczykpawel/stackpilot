#!/bin/bash

# StackPilot - Add Static Hosting
# Adds public static file hosting via Caddy file_server.
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   ./local/add-static-hosting.sh DOMAIN [SSH_ALIAS] [LOCAL_DIR] [REMOTE_DIR]
#
# Examples:
#   ./local/add-static-hosting.sh cdn.example.com
#   ./local/add-static-hosting.sh cdn.example.com vps ./dist
#   ./local/add-static-hosting.sh cdn.example.com vps ./dist /var/www/assets

set -e

DOMAIN="$1"
SSH_ALIAS="${2:-vps}"
LOCAL_DIR="${3:-}"
REMOTE_DIR="${4:-/var/www/$DOMAIN}"

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 DOMAIN [SSH_ALIAS] [LOCAL_DIR] [REMOTE_DIR]"
    echo ""
    echo "Examples:"
    echo "  $0 cdn.example.com vps                              # use existing files on server"
    echo "  $0 cdn.example.com vps ./dist                       # upload ./dist -> /var/www/cdn.example.com"
    echo "  $0 cdn.example.com vps ./dist /var/www/assets        # upload ./dist -> /var/www/assets"
    echo ""
    echo "Defaults:"
    echo "  SSH_ALIAS:  vps"
    echo "  REMOTE_DIR: /var/www/DOMAIN"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

_ASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_ASH_DIR/../lib/i18n.sh"
fi

msg ""
msg "$MSG_ASH_HEADER"
msg ""
msg "$MSG_ASH_DOMAIN" "$DOMAIN"
msg "$MSG_ASH_SERVER" "$SSH_ALIAS"
if [ -n "$LOCAL_DIR" ]; then
    echo "   Local dir: $LOCAL_DIR"
fi
msg "$MSG_ASH_DIR" "$REMOTE_DIR"
msg ""

msg "$MSG_ASH_MODE"

# Create remote directory
server_exec "sudo mkdir -p '$REMOTE_DIR' && sudo chown -R \$(whoami) '$REMOTE_DIR' && sudo chmod -R o+rX '$REMOTE_DIR'"

# Upload local files if LOCAL_DIR provided
if [ -n "$LOCAL_DIR" ]; then
    if [ ! -d "$LOCAL_DIR" ]; then
        echo "❌ Local directory not found: $LOCAL_DIR"
        exit 1
    fi
    echo "   Uploading files..."
    rsync -az --delete --exclude='.git' --exclude='node_modules' \
        "$LOCAL_DIR/" "${SSH_ALIAS}:${REMOTE_DIR}/"
    echo "✅ Files uploaded"
fi

# Install Caddy if missing
if ! server_exec "command -v sp-expose >/dev/null 2>&1"; then
    msg "$MSG_ASH_CADDY_INSTALLING"
    server_exec "bash -s" < "$SCRIPT_DIR/../system/caddy-install.sh" || { msg "$MSG_ASH_CADDY_FAIL"; exit 1; }
    msg "$MSG_ASH_CADDY_INSTALLED"
else
    msg "$MSG_ASH_CADDY_ALREADY"
fi

# Configure DNS via Cloudflare if available
if [ -f "$SCRIPT_DIR/dns-add.sh" ]; then
    "$SCRIPT_DIR/dns-add.sh" "$DOMAIN" "$SSH_ALIAS" || msg "$MSG_ASH_DNS_MAYBE_EXISTS"
fi

# Configure Caddy (with remote path)
server_exec "sp-expose '$DOMAIN' '$REMOTE_DIR' static"

msg "$MSG_ASH_CADDY_CONFIGURED"

msg ""
msg "$MSG_ASH_READY"
msg ""
msg "$MSG_ASH_URL" "$DOMAIN"
msg "$MSG_ASH_FILES" "$REMOTE_DIR"
msg ""
msg "$MSG_ASH_UPLOAD" "$SSH_ALIAS" "$REMOTE_DIR"
msg "$MSG_ASH_VERIFY" "$DOMAIN"
msg ""
