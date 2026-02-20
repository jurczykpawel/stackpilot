#!/bin/bash

# StackPilot - Redis
# In-memory data store. Useful for n8n caching or queues.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=130  # redis:alpine
#
# Optional environment variables:
#   REDIS_PASS - password for Redis (if not set, generated automatically)

set -e

APP_NAME="redis"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-6379}

echo "--- ⚡ Redis Setup ---"

# Generate password if not provided
if [ -z "$REDIS_PASS" ]; then
    REDIS_PASS=$(openssl rand -hex 16)
    echo "✅ Redis password generated"
else
    echo "✅ Using password from configuration"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Save password to file for reference
echo "$REDIS_PASS" | sudo tee .redis_password > /dev/null
sudo chmod 600 .redis_password

# Docker network — so other containers (n8n etc.) can reach Redis by name
DOCKER_NETWORK="${REDIS_NETWORK:-docker_network}"
if ! sudo docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
    sudo docker network create "$DOCKER_NETWORK"
    echo "✅ Created Docker network: $DOCKER_NETWORK"
else
    echo "✅ Docker network: $DOCKER_NETWORK (exists)"
fi

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  redis:
    image: redis:alpine
    container_name: redis
    restart: always
    command: redis-server --requirepass $REDIS_PASS --save 60 1 --loglevel warning --appendonly yes
    ports:
      - "127.0.0.1:$PORT:6379"
    volumes:
      - ./data:/data
    networks:
      - $DOCKER_NETWORK
    deploy:
      resources:
        limits:
          memory: 128M

networks:
  $DOCKER_NETWORK:
    external: true

EOF

sudo docker compose up -d

# Health check (redis doesn't have HTTP, just check container)
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type check_container_running &>/dev/null; then
    check_container_running "$APP_NAME" || { echo "❌ Installation failed!"; exit 1; }
else
    sleep 3
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Redis is running on port $PORT"
    else
        echo "❌ Container failed to start!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

echo ""
echo "✅ Redis installed!"
echo "   Port: 127.0.0.1:$PORT (local only)"
echo "   Docker network: $DOCKER_NETWORK (other containers connect via host: redis)"
echo "   Password saved in: $STACK_DIR/.redis_password"
echo ""
echo "   From host:      redis-cli -h 127.0.0.1 -p $PORT -a \$(cat $STACK_DIR/.redis_password)"
echo "   From container: host=redis, port=6379, password from file above"
