#!/bin/bash

# StackPilot - Add Static Hosting
# Adds public static file hosting.
# Uses nginx in Docker for Cytrus or Caddy file_server for Cloudflare.
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/add-static-hosting.sh DOMAIN [SSH_ALIAS] [DIRECTORY] [PORT]
#
# Examples:
#   ./local/add-static-hosting.sh static.byst.re
#   ./local/add-static-hosting.sh static.byst.re vps /var/www/public 8096
#   ./local/add-static-hosting.sh cdn.example.com vps /var/www/assets 8097

set -e

DOMAIN="$1"
SSH_ALIAS="${2:-vps}"
WEB_ROOT="${3:-/var/www/public}"
PORT="${4:-8096}"

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 DOMAIN [SSH_ALIAS] [DIRECTORY] [PORT]"
    echo ""
    echo "Examples:"
    echo "  $0 static.byst.re                              # Cytrus, default settings"
    echo "  $0 cdn.example.com vps                          # Cloudflare"
    echo "  $0 assets.byst.re vps /var/www/assets 8097     # Custom directory and port"
    echo ""
    echo "Defaults:"
    echo "  SSH_ALIAS: vps"
    echo "  DIRECTORY: /var/www/public"
    echo "  PORT:      8096"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

echo ""
echo "🌍 Adding Static Hosting"
echo ""
echo "   Domain:    $DOMAIN"
echo "   Server:    $SSH_ALIAS"
echo "   Directory: $WEB_ROOT"
echo "   Port:      $PORT"
echo ""

# Detect domain type
is_cytrus_domain() {
    case "$1" in
        *.byst.re|*.bieda.it|*.toadres.pl|*.tojest.dev|*.mikr.us|*.srv24.pl|*.vxm.pl) return 0 ;;
        *) return 1 ;;
    esac
}

if is_cytrus_domain "$DOMAIN"; then
    echo "🍊 Mode: Cytrus (nginx in Docker)"

    # Create directory
    server_exec "sudo mkdir -p '$WEB_ROOT' && sudo chown -R 1000:1000 '$WEB_ROOT' && sudo chmod -R o+rX '$WEB_ROOT'"

    # Check if port is free
    if server_exec "netstat -tlnp 2>/dev/null | grep -q ':$PORT ' || ss -tlnp | grep -q ':$PORT '"; then
        echo "❌ Port $PORT is already in use!"
        echo "   Use a different port: $0 $DOMAIN $SSH_ALIAS $WEB_ROOT OTHER_PORT"
        exit 1
    fi

    # Start nginx
    STACK_NAME="static-$(echo "$DOMAIN" | sed 's/\./-/g')"
    server_exec "mkdir -p /opt/stacks/$STACK_NAME && cat > /opt/stacks/$STACK_NAME/docker-compose.yaml << 'EOF'
services:
  nginx:
    image: nginx:alpine
    restart: always
    ports:
      - \"$PORT:80\"
    volumes:
      - $WEB_ROOT:/usr/share/nginx/html:ro
    deploy:
      resources:
        limits:
          memory: 32M
EOF
cd /opt/stacks/$STACK_NAME && docker compose up -d"

    echo "✅ nginx started on port $PORT"

    # Register domain
    echo ""
    "$SCRIPT_DIR/cytrus-domain.sh" "$DOMAIN" "$PORT" "$SSH_ALIAS"

else
    echo "☁️  Mode: Cloudflare (Caddy file_server)"

    # Create directory
    server_exec "sudo mkdir -p '$WEB_ROOT' && sudo chown -R 1000:1000 '$WEB_ROOT' && sudo chmod -R o+rX '$WEB_ROOT'"

    # Configure DNS
    "$SCRIPT_DIR/dns-add.sh" "$DOMAIN" "$SSH_ALIAS" || echo "DNS may already exist"

    # Configure Caddy
    server_exec "sp-expose '$DOMAIN' '$WEB_ROOT' static"

    echo "✅ Caddy configured"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ Static Hosting ready!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "🌍 URL: https://$DOMAIN"
echo "📂 Files: $WEB_ROOT"
echo ""
echo "Upload file: ssh $SSH_ALIAS 'echo test > $WEB_ROOT/test.txt'"
echo "Verify:      curl https://$DOMAIN/test.txt"
echo ""
