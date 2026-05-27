#!/bin/bash

# StackPilot - Immich (Self-hosted Google Photos)
# Face recognition, CLIP search, mobile backup — your photos, your server.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=3000  # immich-server + immich-machine-learning + postgres + valkey
#
# NOTE: ML service downloads CLIP and face recognition models on first use (~1-2 GB).
# Initial startup takes 5-10 minutes on a cold server.
# Monitor progress: docker compose logs -f immich-machine-learning
#
# MEMORY: Minimum 3.5 GB RAM. Recommended: 4 GB (Mikrus 3.5 / Hetzner CAX11+).

set -e

APP_NAME="immich"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-2283}

if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

DB_PASSWORD=${DB_PASSWORD:-$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32)}
DB_USERNAME="postgres"
DB_DATABASE_NAME="immich"

echo "--- 📸 Immich Setup ---"
echo "Self-hosted Google Photos: face recognition, CLIP search, mobile backup."
echo ""

# Warn on low RAM
AVAIL_RAM=$(free -m | awk '/^Mem:/ {print $2}')
if [ "${AVAIL_RAM}" -lt 3500 ]; then
    echo "⚠️  Warning: ${AVAIL_RAM}MB RAM detected. Immich needs ~3.5 GB for ML."
    echo "   Recommended: Mikrus 3.5 (4 GB RAM) or Hetzner CAX11."
    echo ""
fi

# Create directories
sudo mkdir -p "$STACK_DIR/library"
sudo mkdir -p "$STACK_DIR/postgres"
sudo mkdir -p "$STACK_DIR/model-cache"
cd "$STACK_DIR"

# Write .env (Immich reads this via env_file)
cat <<EOF | sudo tee .env > /dev/null
# Immich environment — managed by StackPilot
UPLOAD_LOCATION=./library
DB_DATA_LOCATION=./postgres
DB_PASSWORD=${DB_PASSWORD}
DB_USERNAME=${DB_USERNAME}
DB_DATABASE_NAME=${DB_DATABASE_NAME}
IMMICH_VERSION=release
IMMICH_HOST_PORT=${PORT}
BIND_ADDR=${BIND_ADDR}
EOF

sudo chmod 600 .env

# Write docker-compose.yaml
# Images from: https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
cat <<'COMPOSE' | sudo tee docker-compose.yaml > /dev/null
name: immich

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
    volumes:
      - ${UPLOAD_LOCATION:-./library}:/data
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - "${BIND_ADDR}${IMMICH_HOST_PORT:-2283}:2283"
    depends_on:
      - redis
      - database
    restart: always
    healthcheck:
      disable: false
    deploy:
      resources:
        limits:
          memory: 1024M

  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}
    volumes:
      - ./model-cache:/cache
    env_file:
      - .env
    restart: always
    healthcheck:
      disable: false
    deploy:
      resources:
        limits:
          memory: 1024M

  redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:9
    healthcheck:
      test: redis-cli ping || exit 1
    restart: always
    deploy:
      resources:
        limits:
          memory: 64M

  database:
    container_name: immich_postgres
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      - ${DB_DATA_LOCATION:-./postgres}:/var/lib/postgresql/data
    shm_size: 128mb
    restart: always
    healthcheck:
      disable: false
    deploy:
      resources:
        limits:
          memory: 1536M
COMPOSE

echo "--- Pulling images (may take a few minutes on first run) ---"
sudo docker compose pull

echo "--- Starting Immich ---"
sudo docker compose up -d

# Wait for the server to respond (up to 120s)
echo "--- Waiting for Immich to start ---"
READY=0
for i in $(seq 1 24); do
    if sudo docker compose exec -T immich-server wget -qO- http://localhost:2283/api/server/ping 2>/dev/null | grep -q pong; then
        READY=1
        break
    fi
    echo "   ... ${i}/24 (${i}0s elapsed)"
    sleep 5
done

if [ "$READY" -eq 0 ]; then
    echo "⚠️  Immich did not respond in 120s. Check logs:"
    echo "   ssh <server> 'cd /opt/stacks/immich && docker compose logs --tail 50'"
else
    echo "✅ Immich is responding."
fi

# Configure reverse proxy if domain provided
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "--- Configuring HTTPS via Caddy ---"
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    else
        echo "⚠️  sp-expose not found — configure reverse proxy manually."
    fi
fi

echo ""
echo "✅ Immich installed!"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗  https://$DOMAIN"
else
    echo "🔗  SSH tunnel: ssh -L ${PORT}:localhost:${PORT} <server>"
    echo "    Then open:  http://localhost:${PORT}"
fi
echo ""
echo "First-time setup:"
echo "  1. Open the URL above and register the first account (auto-becomes admin)."
echo "  2. Install the Immich app on iOS/Android and point it to this server."
echo "  3. ML models download on first use (~1-2 GB). Face recognition"
echo "     activates ~5 min after the first photo is uploaded."
echo ""
echo "Useful commands:"
echo "  Logs:    ssh <server> 'cd /opt/stacks/immich && docker compose logs -f'"
echo "  Update:  ssh <server> 'cd /opt/stacks/immich && docker compose pull && docker compose up -d'"
