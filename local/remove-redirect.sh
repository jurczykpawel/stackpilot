#!/bin/bash

# StackPilot - Remove Redirect
# Removes a previously-added redirect from a domain's Caddy block.
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   ./local/remove-redirect.sh DOMAIN PATH [SSH_ALIAS]
#
# Examples:
#   ./local/remove-redirect.sh techskills.academy /protocol-autonomy
#   ./local/remove-redirect.sh techskills.academy /old mikrus

set -e

DOMAIN="$1"
RPATH="$2"
SSH_ALIAS="${3:-vps}"

if [ -z "$DOMAIN" ] || [ -z "$RPATH" ]; then
    echo "Usage: $0 DOMAIN PATH [SSH_ALIAS]"
    echo ""
    echo "Example:"
    echo "  $0 techskills.academy /protocol-autonomy mikrus"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

echo ""
echo "🗑️  StackPilot - Remove Redirect"
echo ""
echo "   Source: https://$DOMAIN$RPATH"
echo "   Server: $SSH_ALIAS"
echo ""

if ! server_exec "command -v sp-redirect >/dev/null 2>&1"; then
    echo "❌ sp-redirect not found on $SSH_ALIAS."
    exit 1
fi

server_exec "sp-redirect remove '$DOMAIN' '$RPATH'"
echo ""
