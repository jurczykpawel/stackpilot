#!/bin/bash

# StackPilot - Dockge Installation
# A lightweight Docker Compose manager (Perfect for Mikrus)
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=150  # louislam/dockge:1

set -e

# Configuration
DOCKGE_DIR="/opt/dockge"
STACKS_DIR="/opt/stacks"
PORT=${PORT:-5001}

echo "--- 1. Checking Prerequisites ---"
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Running system/docker-setup.sh first..."
    # We assume the user has the toolbox repo or we just run the setup
    curl -s https://raw.githubusercontent.com/unkn0w/noobs/main/scripts/chce_dockera.sh | bash
fi

echo "--- 2. Creating Directories ---"
sudo mkdir -p "$DOCKGE_DIR" "$STACKS_DIR"
cd "$DOCKGE_DIR"

echo "--- 3. Downloading Dockge Compose File ---"
# We create it manually to ensure it's optimized
cat <<EOF | sudo tee docker-compose.yaml
services:
  dockge:
    image: louislam/dockge:1
    restart: always
    ports:
      - "$PORT:5001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/app/data
      - $STACKS_DIR:$STACKS_DIR
    environment:
      # Tell Dockge where the stacks are located
      - DOCKGE_STACKS_DIR=$STACKS_DIR
EOF

echo "--- 4. Starting Dockge ---"
sudo docker compose up -d

# Health check
export STACK_DIR="$DOCKGE_DIR"
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "dockge" "$PORT" 45 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Dockge działa na porcie $PORT"
    else
        echo "❌ Kontener nie wystartował!"; sudo docker compose logs --tail 20; exit 1
    fi
fi
echo ""
echo "📂 Stacks: $STACKS_DIR"
