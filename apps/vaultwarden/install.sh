#!/bin/bash

# Mikrus Toolbox - Vaultwarden
# Lightweight Bitwarden server written in Rust.
# Secure password management for your business.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=330  # vaultwarden/server:latest
#
# Opcjonalne zmienne środowiskowe:
#   DOMAIN - domena dla Vaultwarden
#   ADMIN_TOKEN - token dla panelu admina (jeśli brak, generowany automatycznie)

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
    echo "✅ Domena: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domena: automatyczna (Cytrus)"
else
    echo "⚠️  Brak domeny - używam localhost"
fi

# Admin token
if [ -z "$ADMIN_TOKEN" ]; then
    ADMIN_TOKEN=$(openssl rand -hex 32)
    echo "✅ Wygenerowano Admin Token"
else
    echo "✅ Używam Admin Token z konfiguracji"
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
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 30 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Vaultwarden działa"
    else
        echo "❌ Kontener nie wystartował!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Caddy/HTTPS - only for real domains
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ] && [[ "$DOMAIN" != *"pending"* ]] && [[ "$DOMAIN" != *"cytrus"* ]]; then
    if command -v mikrus-expose &> /dev/null; then
        sudo mikrus-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ Vaultwarden started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo ""
echo "   Admin panel: $DOMAIN_URL/admin"
echo "   Admin token zapisany w: $STACK_DIR/.admin_token"
echo ""
echo "⚠️  ACTION REQUIRED:"
echo "1. Create your account NOW."
echo "2. Edit docker-compose.yaml and set SIGNUPS_ALLOWED=false"
echo "3. Run 'docker compose up -d' to apply."
