#!/bin/bash

# Mikrus Toolbox - Redis
# In-memory data store. Useful for n8n caching or queues.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=130  # redis:alpine
#
# Opcjonalne zmienne środowiskowe:
#   REDIS_PASS - hasło do Redis (jeśli brak, generowane automatycznie)

set -e

APP_NAME="redis"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-6379}

echo "--- ⚡ Redis Setup ---"

# Generate password if not provided
if [ -z "$REDIS_PASS" ]; then
    REDIS_PASS=$(openssl rand -hex 16)
    echo "✅ Wygenerowano hasło Redis"
else
    echo "✅ Używam hasła z konfiguracji"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Save password to file for reference
echo "$REDIS_PASS" | sudo tee .redis_password > /dev/null
sudo chmod 600 .redis_password

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  redis:
    image: redis:alpine
    restart: always
    command: redis-server --requirepass $REDIS_PASS --save 60 1 --loglevel warning
    ports:
      - "127.0.0.1:$PORT:6379"
    volumes:
      - ./data:/data
    deploy:
      resources:
        limits:
          memory: 128M

EOF

sudo docker compose up -d

# Health check (redis doesn't have HTTP, just check container)
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type check_container_running &>/dev/null; then
    check_container_running "$APP_NAME" || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    sleep 3
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Redis działa na porcie $PORT"
    else
        echo "❌ Kontener nie wystartował!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

echo ""
echo "✅ Redis zainstalowany!"
echo "   Port: 127.0.0.1:$PORT (tylko lokalnie)"
echo "   Hasło zapisane w: $STACK_DIR/.redis_password"
echo ""
echo "   Połączenie: redis-cli -h 127.0.0.1 -p $PORT -a \$(cat $STACK_DIR/.redis_password)"
