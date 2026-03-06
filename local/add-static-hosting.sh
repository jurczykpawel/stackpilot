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

_ASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_ASH_DIR/../lib/i18n.sh"
fi

msg ""
msg "$MSG_ASH_HEADER"
msg ""
msg "$MSG_ASH_DOMAIN" "$DOMAIN"
msg "$MSG_ASH_SERVER" "$SSH_ALIAS"
msg "$MSG_ASH_DIR" "$WEB_ROOT"
msg ""

msg "$MSG_ASH_MODE"

# Create directory
server_exec "sudo mkdir -p '$WEB_ROOT' && sudo chown -R \$(whoami) '$WEB_ROOT' && sudo chmod -R o+rX '$WEB_ROOT'"

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

# Configure Caddy
server_exec "sp-expose '$DOMAIN' '$WEB_ROOT' static"

msg "$MSG_ASH_CADDY_CONFIGURED"

msg ""
msg "$MSG_ASH_READY"
msg ""
msg "$MSG_ASH_URL" "$DOMAIN"
msg "$MSG_ASH_FILES" "$WEB_ROOT"
msg ""
msg "$MSG_ASH_UPLOAD" "$SSH_ALIAS" "$WEB_ROOT"
msg "$MSG_ASH_VERIFY" "$DOMAIN"
msg ""
