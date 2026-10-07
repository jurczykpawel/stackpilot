#!/bin/bash

# StackPilot - LinkedGrow
# AI agents that find your leads and clients on LinkedIn. Alternative to Expandi/Dripify.
# https://github.com/DigiHold/LinkedGrow
# Author: Nicolas Lecocq
#
# IMAGE_SIZE_MB=4000  # linkedgrow + linkedgrow-worker + libsql-server
# DB_BUNDLED=true
#
# Dedicated server recommended (min. 4GB RAM). The worker drives a real Chrome
# per connected LinkedIn account, because LinkedGrow uses no LinkedIn API.
#
# Stack: 3 containers
#   - db      libsql-server, the database
#   - app     Next.js dashboard on port 3000
#   - worker  Chrome under Xvfb, runs the agents and the publishing
#
# The app writes its own AUTH_SECRET and ENCRYPTION_KEY into ./config on the
# first start and the worker reads them back from the same directory. Both are
# needed to read anything the instance stored, so ./config belongs in the
# backup set with ./db-data.

set -e

APP_NAME="linkedgrow"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}
LINKEDGROW_VERSION=${LINKEDGROW_VERSION:-latest}

echo "--- LinkedGrow Setup ---"
echo "AI agents that find your leads and clients on LinkedIn."
echo ""

# Port binding: Cytrus needs 0.0.0.0, Cloudflare/local -> 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

# RAM check and worker sizing. One worker slot is one concurrent Chrome.
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")

if [ "$TOTAL_RAM" -ge 16000 ]; then
    WORKER_SLOTS=8
elif [ "$TOTAL_RAM" -ge 8000 ]; then
    WORKER_SLOTS=4
elif [ "$TOTAL_RAM" -ge 3500 ]; then
    WORKER_SLOTS=2
else
    WORKER_SLOTS=1
fi
WORKER_SLOTS=${WORKER_SLOTS_OVERRIDE:-$WORKER_SLOTS}

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 3500 ]; then
    echo ""
    echo "WARNING: LinkedGrow recommends at least 4GB RAM."
    echo "  Your server: ${TOTAL_RAM}MB"
    echo "  Recommended: 4096MB"
    echo "  The worker runs a real Chrome per LinkedIn account, so WORKER_SLOTS is set to 1."
    echo ""
fi

echo "Worker slots (concurrent Chrome sessions): $WORKER_SLOTS"

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "Domain: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "Domain: assigned automatically (Cytrus)"
else
    echo "No domain given. Reach the app over an SSH tunnel, or pass --domain=..."
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Both images run as uid 10001 and refuse to start on a directory they cannot
# write, so the bind mounts are created and chowned before the first run.
sudo mkdir -p "$STACK_DIR"/{db-data,config,uploads,profiles}
sudo chown -R 10001:10001 "$STACK_DIR"/{db-data,config,uploads,profiles}

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  # --- Database (libSQL, no external database needed) ---
  db:
    image: "ghcr.io/tursodatabase/libsql-server:latest"
    restart: always
    environment:
      - SQLD_NODE=primary
      - SQLD_DB_PATH=/var/lib/sqld/iku.db
    volumes:
      - ./db-data:/var/lib/sqld
    networks:
      - linkedgrow-network
    deploy:
      resources:
        limits:
          memory: 512M

  # --- App (Next.js dashboard) ---
  app:
    image: "ghcr.io/digihold/linkedgrow:$LINKEDGROW_VERSION"
    restart: always
    ports:
      - "${BIND_ADDR}$PORT:3000"
    environment:
      - TURSO_DATABASE_URL=http://db:8080
      - TURSO_AUTH_TOKEN=
      - LINKEDGROW_EDITION=self-hosted
      - STORAGE_ROOT=/data/uploads
      - CONFIG_DIR=/data/config
    volumes:
      - ./uploads:/data/uploads
      - ./config:/data/config
    networks:
      - linkedgrow-network
    depends_on:
      - db
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 90s
    deploy:
      resources:
        limits:
          memory: 1024M

  # --- Worker (Chrome under Xvfb, agents and publishing) ---
  # Starts only once the app answers its health check, because it reads the
  # secrets the app generates into ./config on the first start.
  worker:
    image: "ghcr.io/digihold/linkedgrow-worker:$LINKEDGROW_VERSION"
    restart: always
    environment:
      - TURSO_DATABASE_URL=http://db:8080
      - TURSO_AUTH_TOKEN=
      - LINKEDGROW_EDITION=self-hosted
      - WORKER_ENV=production
      - APP_INTERNAL_URL=http://app:3000
      - WORKER_SLOTS=$WORKER_SLOTS
      - CONFIG_DIR=/data/config
    shm_size: "2gb"
    volumes:
      - ./profiles:/data/profiles
      - ./uploads:/data/uploads
      - ./config:/data/config:ro
    networks:
      - linkedgrow-network
    depends_on:
      app:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 3072M

networks:
  linkedgrow-network:
EOF

echo ""
echo "Docker Compose written (3 containers). Starting the stack..."
echo ""

sudo docker compose up -d

# First start pulls about 4GB and applies the migrations, so give it room.
echo "Waiting for LinkedGrow (first start pulls ~4GB, allow 3-5 minutes)..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 300 "/api/health" || { echo "Installation failed."; exit 1; }
else
    for i in $(seq 1 30); do
        sleep 10
        if curl -sf "http://localhost:$PORT/api/health" > /dev/null 2>&1; then
            echo "LinkedGrow is up (after $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 30 ]; then
            echo "The app did not answer within 300s."
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

echo ""
echo "================================================================"
echo "LinkedGrow installed."
echo "================================================================"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "The domain is configured automatically after installation."
else
    echo "SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo ""
echo "Next steps:"
echo "   1. Create the first account. It administers the instance and sign ups close after it."
echo "   2. Answer the setup wizard once: AI key, spending ceilings, proxy supplier, email, storage."
echo "   3. Connect a LinkedIn account and create an agent."
echo ""
echo "IMPORTANT - back up $STACK_DIR/config together with $STACK_DIR/db-data."
echo "   It holds AUTH_SECRET and ENCRYPTION_KEY. Without ENCRYPTION_KEY every"
echo "   stored LinkedIn password, 2FA secret and API key stays unreadable."
echo ""
echo "Docs: https://github.com/DigiHold/LinkedGrow"
