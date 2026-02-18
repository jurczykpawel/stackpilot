#!/bin/bash

# StackPilot - Uptime Kuma
# Self-hosted monitoring tool like "Uptime Robot".
# Very lightweight.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=500  # louislam/uptime-kuma:1

set -e

APP_NAME="uptime-kuma"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3001}

echo "--- 📈 Uptime Kuma Setup ---"

# Setup Dir
sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Compose
cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    restart: always
    ports:
      - "$PORT:3001"
    volumes:
      - ./data:/app/data
    deploy:
      resources:
        limits:
          memory: 256M
EOF

# Start
sudo docker compose up -d

# Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 45 || { echo "❌ Installation failed!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Uptime Kuma is running on port $PORT"
    else
        echo "❌ Container failed to start!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

echo ""
echo "📊 First login: create an admin account in the browser"
