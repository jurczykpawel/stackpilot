#!/bin/bash

# StackPilot - Vaultwarden
# Lightweight Bitwarden server written in Rust.
# Secure password management for your business.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=330  # vaultwarden/server:latest
#
# Optional environment variables:
#   DOMAIN - domain for Vaultwarden
#   ADMIN_TOKEN - token for admin panel (if not set, generated automatically)

set -e

APP_NAME="vaultwarden"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8088}

echo "--- 🔐 Vaultwarden Setup ---"
echo "NOTE: Once installed, create your account immediately."
echo "Then, restart the container with SIGNUPS_ALLOWED=false to secure it."
echo ""

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Caddy)"
else
    echo "⚠️  No domain - using localhost"
fi

# Admin token
if [ -z "$ADMIN_TOKEN" ]; then
    ADMIN_TOKEN=$(openssl rand -hex 32)
    echo "✅ Admin Token generated"
else
    echo "✅ Using Admin Token from configuration"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Save admin token for reference
echo "$ADMIN_TOKEN" | sudo tee .admin_token > /dev/null
sudo chmod 600 .admin_token

# Set domain URL
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    DOMAIN_URL="https://$DOMAIN"
else
    DOMAIN_URL="http://localhost:$PORT"
fi

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  vaultwarden:
    image: vaultwarden/server:latest
    restart: always
    ports:
      - "$PORT:80"
    environment:
      - DOMAIN=$DOMAIN_URL
      - SIGNUPS_ALLOWED=true
      - ADMIN_TOKEN=$ADMIN_TOKEN
      - WEBSOCKET_ENABLED=true
    volumes:
      - ./data:/data
    deploy:
      resources:
        limits:
          memory: 128M

EOF

sudo docker compose up -d

# Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 30 || { echo "❌ Installation failed!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Vaultwarden is running"
    else
        echo "❌ Container failed to start!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Caddy/HTTPS - configure reverse proxy if domain is set
if [ -n "$DOMAIN" ]; then
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ Vaultwarden started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo ""
echo "   Admin panel: $DOMAIN_URL/admin"
echo "   Admin token saved in: $STACK_DIR/.admin_token"
echo ""
echo "📝 Next steps:"
echo "   1. Create your account in the browser"
echo "   2. Disable registration (command below!)"
echo ""
echo "🔒 IMPORTANT — disable registration after creating your account:"
echo "   ssh ${SSH_ALIAS:-vps} 'cd $STACK_DIR && sed -i \"s/SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/\" docker-compose.yaml && docker compose up -d'"
