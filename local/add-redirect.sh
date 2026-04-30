#!/bin/bash

# StackPilot - Add Redirect
# Adds an HTTP redirect (path-level) to an existing domain via Caddy.
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   ./local/add-redirect.sh DOMAIN PATH TARGET [SSH_ALIAS] [--code=301|302]
#
# Examples:
#   ./local/add-redirect.sh techskills.academy /protocol-autonomy https://sellf.techskills.academy/protocol-autonomy
#   ./local/add-redirect.sh techskills.academy /old https://new.example.com mikrus --code=302
#
# The domain must already be configured (via add-static-hosting.sh, add-php-hosting.sh,
# or any other deploy.sh flow). The redirect is added inside the existing site block,
# so it inherits TLS settings (including `tls internal` for Cloudflare Full mode).

set -e

DOMAIN="$1"
RPATH="$2"
TARGET="$3"
SSH_ALIAS="${4:-vps}"
CODE_FLAG="${5:-}"

# Allow --code=... in any position
for arg in "$@"; do
    case "$arg" in
        --code=*) CODE_FLAG="$arg" ;;
    esac
done

if [ -z "$DOMAIN" ] || [ -z "$RPATH" ] || [ -z "$TARGET" ]; then
    echo "Usage: $0 DOMAIN PATH TARGET [SSH_ALIAS] [--code=301|302]"
    echo ""
    echo "Examples:"
    echo "  $0 techskills.academy /protocol-autonomy https://sellf.techskills.academy/protocol-autonomy"
    echo "  $0 techskills.academy /old https://new.example.com mikrus --code=302"
    echo ""
    echo "Defaults:"
    echo "  SSH_ALIAS: vps"
    echo "  --code:    301 (permanent)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

echo ""
echo "🔀 StackPilot - Add Redirect"
echo ""
echo "   Source: https://$DOMAIN$RPATH"
echo "   Target: $TARGET"
echo "   Server: $SSH_ALIAS"
[ -n "$CODE_FLAG" ] && echo "   Code:   $CODE_FLAG"
echo ""

if ! server_exec "command -v sp-redirect >/dev/null 2>&1"; then
    echo "❌ sp-redirect not found on $SSH_ALIAS."
    echo "   Run: ./local/add-static-hosting.sh DOMAIN $SSH_ALIAS  (installs Caddy + sp-redirect)"
    exit 1
fi

# Build args (CODE_FLAG may be empty)
if [ -n "$CODE_FLAG" ]; then
    server_exec "sp-redirect add '$DOMAIN' '$RPATH' '$TARGET' '$CODE_FLAG'"
else
    server_exec "sp-redirect add '$DOMAIN' '$RPATH' '$TARGET'"
fi

echo ""
echo "🔍 Verify: curl -I https://$DOMAIN$RPATH"
echo ""
