#!/bin/bash

# StackPilot - Add Static Hosting
# Adds public static file hosting via Caddy file_server.
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   ./local/add-static-hosting.sh DOMAIN [SSH_ALIAS] [DIRECTORY]
#
# Examples:
#   ./local/add-static-hosting.sh cdn.example.com
#   ./local/add-static-hosting.sh cdn.example.com vps /var/www/assets

set -e

DOMAIN="$1"
SSH_ALIAS="${2:-vps}"
WEB_ROOT="${3:-/var/www/public}"

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 DOMAIN [SSH_ALIAS] [DIRECTORY]"
    echo ""
    echo "Examples:"
    echo "  $0 cdn.example.com vps                          # Cloudflare + Caddy"
    echo "  $0 assets.example.com vps /var/www/assets        # Custom directory"
    echo ""
    echo "Defaults:"
    echo "  SSH_ALIAS: vps"
    echo "  DIRECTORY: /var/www/public"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

echo ""
echo "Adding Static Hosting"
echo ""
echo "   Domain:    $DOMAIN"
echo "   Server:    $SSH_ALIAS"
echo "   Directory: $WEB_ROOT"
echo ""

echo "Mode: Caddy file_server"

# Create directory
server_exec "sudo mkdir -p '$WEB_ROOT' && sudo chown -R \$(whoami) '$WEB_ROOT' && sudo chmod -R o+rX '$WEB_ROOT'"

# Install Caddy if missing
if ! server_exec "command -v sp-expose >/dev/null 2>&1"; then
    echo "Installing Caddy + sp-expose..."
    server_exec "bash -s" < "$SCRIPT_DIR/../system/caddy-install.sh" || { echo "Caddy install failed"; exit 1; }
    echo "Caddy installed"
else
    echo "Caddy already installed"
fi

# Configure DNS via Cloudflare if available
if [ -f "$SCRIPT_DIR/dns-add.sh" ]; then
    "$SCRIPT_DIR/dns-add.sh" "$DOMAIN" "$SSH_ALIAS" || echo "DNS may already exist"
fi

# Configure Caddy
server_exec "sp-expose '$DOMAIN' '$WEB_ROOT' static"

echo "Caddy configured"

echo ""
echo "Static Hosting ready!"
echo ""
echo "URL: https://$DOMAIN"
echo "Files: $WEB_ROOT"
echo ""
echo "Upload file: ssh $SSH_ALIAS 'echo test > $WEB_ROOT/test.txt'"
echo "Verify:      curl https://$DOMAIN/test.txt"
echo ""
