#!/bin/bash

# StackPilot - LinkStack
# Self-hosted "Link in Bio" page.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=550  # linkstackorg/linkstack:latest
#
# Optional environment variables:
#   DOMAIN - domain for LinkStack

set -e

APP_NAME="linkstack"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8090}

# Port binding: Cytrus needs 0.0.0.0, Cloudflare/Caddy/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

echo "--- 🔗 LinkStack Setup ---"

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Caddy)"
else
    echo "⚠️  No domain - using localhost"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Check if this is a first install (no files in data/)
if [ ! -f "./data/index.php" ]; then
    echo "📦 First install - downloading application files..."

    # Temporary container without volume
    cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  linkstack:
    image: linkstackorg/linkstack
    restart: "no"
EOF

    # Start temporarily to copy files
    sudo docker compose up -d
    sleep 5

    # Copy files from container to host
    sudo mkdir -p data
    CONTAINER_ID=$(sudo docker compose ps -q linkstack)
    sudo docker cp "$CONTAINER_ID:/htdocs/." ./data/
    sudo docker compose down

    # Set permissions for Apache
    sudo chown -R 100:101 data
    echo "✅ Application files copied"
fi

# Final docker-compose with bind mount
cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  linkstack:
    image: linkstackorg/linkstack
    restart: always
    ports:
      - "${BIND_ADDR}$PORT:80"
    volumes:
      - ./data:/htdocs
    environment:
      - SERVER_ADMIN=admin@localhost
      - TZ=Europe/Warsaw
    deploy:
      resources:
        limits:
          memory: 256M
EOF

sudo docker compose up -d

# Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 45 || { echo "❌ Installation failed!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ LinkStack is running"
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
echo "✅ LinkStack started!"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open: https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
    echo "   Then open: http://localhost:$PORT"
fi
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📋 SETUP WIZARD - what to choose?"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "   🎯 Are you a solopreneur / have a single profile?"
echo "      → Choose SQLite and don't worry about it"
echo ""
echo "   🏢 Setting this up for a company with multiple employees?"
echo "      → MySQL (use your database credentials)"
echo ""
echo "   📝 Save your admin login credentials - you'll need them later!"
echo ""
