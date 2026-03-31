#!/bin/bash

# StackPilot - ntfy.sh
# Self-hosted push notifications server.
# Send alerts from n8n directly to your phone.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=50  # binwiederhier/ntfy:latest (very lightweight)

set -e

APP_NAME="ntfy"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8085}

echo "--- 🔔 ntfy Setup ---"

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Domain for BASE_URL
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    NTFY_BASE_URL="https://$DOMAIN"
    echo "✅ Domain: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    NTFY_BASE_URL="https://notify.example.com"
    echo "✅ Domain: automatic (Caddy) — BASE_URL will be updated"
else
    NTFY_BASE_URL="https://notify.example.com"
    echo "⚠️  No domain - use --domain=... or update BASE_URL later"
fi

# Basic config with cache enabled
cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  ntfy:
    image: binwiederhier/ntfy
    restart: always
    command: serve
    environment:
      - NTFY_BASE_URL=$NTFY_BASE_URL
      - NTFY_CACHE_FILE=/var/cache/ntfy/cache.db
      - NTFY_AUTH_FILE=/var/cache/ntfy/user.db
      - NTFY_AUTH_DEFAULT_ACCESS=deny-all
      - NTFY_BEHIND_PROXY=true
    volumes:
      - ./cache:/var/cache/ntfy
    ports:
      - "$PORT:80"
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O- http://localhost/v1/health | grep -q healthy || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 10s
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
        echo "✅ ntfy is running on port $PORT"
    else
        echo "❌ Container failed to start!"; sudo docker compose logs --tail 20; exit 1
    fi
fi
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo ""
echo "👤 Create a user for ntfy login:"
echo "   ssh $SSH_ALIAS 'docker exec -it ntfy-ntfy-1 ntfy user add --role=admin YOUR_USER'"
echo "   (this is an internal ntfy user, not a system user)"
