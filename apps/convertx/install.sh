#!/bin/bash

# StackPilot - ConvertX
# Self-hosted file converter. Images, documents, audio, video - 1000+ formats.
# https://github.com/C4illin/ConvertX
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=5300  # ghcr.io/c4illin/convertx:latest (1.4GB compressed → 5.3GB on disk)

set -e

APP_NAME="convertx"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}

echo "--- 🔄 ConvertX Setup ---"
echo "Universal file converter in your browser."
echo ""

if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

# JWT secret - without this, sessions are lost after container restart
JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Caddy)"
else
    echo "⚠️  No domain - use --domain=... or access via SSH tunnel"
fi

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  convertx:
    image: ghcr.io/c4illin/convertx:latest
    restart: always
    ports:
      - "${BIND_ADDR}$PORT:3000"
    environment:
      - JWT_SECRET=$JWT_SECRET
      - ACCOUNT_REGISTRATION=true
      - AUTO_DELETE_EVERY_N_HOURS=24
      - TZ=Europe/Warsaw
    volumes:
      - ./data:/app/data
    healthcheck:
      test: ["CMD", "curl", "-f", "-s", "http://localhost:3000/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: 512M
EOF

sudo docker compose up -d

# Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 90 || { echo "❌ Installation failed!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ ConvertX is running on port $PORT"
    else
        echo "❌ Container failed to start!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ ConvertX installed!"
echo "════════════════════════════════════════════════════════════════"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo ""
echo "📝 Next steps:"
echo "   1. Create an admin account in the browser"
echo "   2. After creating the account, disable registration:"
echo "      ssh <server> 'cd $STACK_DIR && sed -i \"s/ACCOUNT_REGISTRATION=true/ACCOUNT_REGISTRATION=false/\" docker-compose.yaml && docker compose up -d'"
echo ""
echo "💡 Files older than 24h are automatically deleted."
echo "   Change AUTO_DELETE_EVERY_N_HOURS in docker-compose.yaml (0 = disable)."
