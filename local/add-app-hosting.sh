#!/bin/bash

# StackPilot - Add App Hosting
# Adds Cloudflare DNS + Caddy reverse proxy for an existing app listening on a
# local port (e.g. a PM2 process, a Docker container). Equivalent to running
#   dns-add.sh DOMAIN  + sp-expose DOMAIN PORT proxy
# in sequence. Use after `deploy.sh ... --domain-type=local` when you want to
# expose an already-running app on a public domain — the "deploy first, add
# domain later" path.
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   ./local/add-app-hosting.sh DOMAIN PORT [SSH_ALIAS]
#
# Examples:
#   ./local/add-app-hosting.sh n8n.example.com 5678
#   ./local/add-app-hosting.sh sellf.example.com 3333 hetzner

set -e

DOMAIN="$1"
PORT="$2"
SSH_ALIAS="${3:-vps}"

if [ -z "$DOMAIN" ] || [ -z "$PORT" ]; then
    echo "Usage: $0 DOMAIN PORT [SSH_ALIAS]"
    echo ""
    echo "Examples:"
    echo "  $0 n8n.example.com 5678                # default ssh: vps"
    echo "  $0 sellf.example.com 3333 hetzner"
    echo ""
    echo "Defaults:"
    echo "  SSH_ALIAS: vps"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"
source "$SCRIPT_DIR/../lib/validation.sh"

_AAH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_AAH_DIR/../lib/i18n.sh"
fi

sp_validate_domain "$DOMAIN" || exit 1
sp_validate_ssh_alias "$SSH_ALIAS" || exit 1

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "Invalid port: $PORT (must be 1-65535)"
    exit 1
fi

echo ""
echo "Add App Hosting"
echo ""
echo "   Domain: $DOMAIN"
echo "   Port:   $PORT"
echo "   Server: $SSH_ALIAS"
echo ""

# Verify the app is actually listening on the port. Without this we would
# happily configure DNS + Caddy and leave users staring at a 502 from Caddy.
echo "Verifying app is responding on localhost:$PORT..."
if ! server_exec "curl -s --max-time 5 http://localhost:$PORT >/dev/null 2>&1"; then
    echo ""
    echo "Nothing is responding on localhost:$PORT — deploy the app first."
    echo "Example: ./local/deploy.sh <app> --ssh=$SSH_ALIAS --domain-type=local --yes"
    exit 1
fi
echo "App is responding."
echo ""

# Install Caddy if sp-expose is missing.
if ! server_exec "command -v sp-expose >/dev/null 2>&1"; then
    echo "Installing Caddy..."
    server_exec "bash -s" < "$SCRIPT_DIR/../system/caddy-install.sh" || { echo "Caddy install failed"; exit 1; }
    echo "Caddy installed."
else
    echo "Caddy already installed."
fi
echo ""

# Frog (Mikrus free tier) blocks inbound IPv6:80 from the public internet,
# so the standard "AAAA + Cloudflare proxy" flow fails with 521. Frog must
# use a Cloudflare Tunnel; DNS is then managed by the Tunnel dashboard, so
# we skip dns-add.sh and pass --cloudflare to sp-expose (HTTP-only block).
IS_FROG=false
if server_exec "[ -f /etc/alpine-release ] && [ ! -f /klucz_api ]" 2>/dev/null; then
    IS_FROG=true
fi

if [ "$IS_FROG" = true ]; then
    if ! server_exec "rc-service cloudflared status >/dev/null 2>&1"; then
        echo ""
        echo "frog server detected but cloudflared tunnel is not running."
        echo "   See docs/frog-setup.md, set up the tunnel, then re-run this script."
        exit 1
    fi
    echo "frog detected — using cloudflared tunnel."
    EXPOSE_FLAGS="--cloudflare"
else
    echo "Configuring Cloudflare DNS (AAAA + proxy)..."
    if [ -f "$SCRIPT_DIR/dns-add.sh" ]; then
        "$SCRIPT_DIR/dns-add.sh" "$DOMAIN" "$SSH_ALIAS" || echo "   (DNS may already exist)"
    fi
    EXPOSE_FLAGS=""
fi
echo ""

echo "Configuring Caddy reverse proxy -> localhost:$PORT..."
server_exec "sp-expose '$DOMAIN' '$PORT' proxy $EXPOSE_FLAGS"
echo ""

echo "Done."
echo ""
echo "   URL:    https://$DOMAIN"
echo "   Verify: curl -I https://$DOMAIN"
echo ""
