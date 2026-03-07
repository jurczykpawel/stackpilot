#!/bin/bash

# StackPilot - AFFiNE
# Open-source knowledge base — Notion + Miro alternative.
# Docs, whiteboards, databases in one tool.
# https://github.com/toeverything/AFFiNE
#
# IMAGE_SIZE_MB=750
# DB_BUNDLED=true  # ghcr.io/toeverything/affine:stable (~273MB) + pgvector/pgvector:pg16 (~350MB) + redis:alpine (~40MB)
#
# REQUIREMENTS:
#   - PostgreSQL 16 with pgvector extension (bundled by default)
#   - Redis (bundled)
#   - Minimum 2GB RAM recommended (app ~1GB + postgres ~256MB + redis ~128MB)
#
# Stack: 4 containers
#   - affine (application)
#   - affine_migration (one-shot DB migration job)
#   - postgres (pgvector/pgvector:pg16)
#   - redis (redis:alpine)
#
# Required environment variables (passed by deploy.sh):
#   DOMAIN (optional)
#   DB_HOST, DB_USER, DB_PASS, DB_NAME (optional — if external DB)

set -e

APP_NAME="affine"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3010}

echo "--- 📝 AFFiNE Setup ---"
echo "Open-source knowledge base (Notion + Miro alternative)."
echo ""

# =============================================================================
# RAM CHECK
# =============================================================================
AVAILABLE_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}' || echo "0")

if [ "$AVAILABLE_RAM" -gt 0 ] && [ "$AVAILABLE_RAM" -lt 1500 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ Not enough RAM for AFFiNE!                              ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Available: ${AVAILABLE_RAM}MB                               ║"
    echo "║  Required:  1500MB+ free (app 1GB + postgres 256MB + redis)  ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Requires 1500MB RAM free. Aborting installation (--yes mode)."
    exit 1
elif [ "$AVAILABLE_RAM" -gt 0 ] && [ "$AVAILABLE_RAM" -lt 2000 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  WARNING: AFFiNE recommends at least 2GB free RAM!      ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Available: ${AVAILABLE_RAM}MB                               ║"
    echo "║  Recommended: 2000MB+ free                                   ║"
    echo "║                                                              ║"
    echo "║  AFFiNE (1GB) + PostgreSQL (256MB) + Redis (128MB)           ║"
    echo "║  On servers with < 2GB free RAM there may be issues.         ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
fi

# =============================================================================
# DATABASE — BUNDLED (pgvector) vs EXTERNAL
# =============================================================================
if [ -n "${DB_HOST:-}" ] && [ -n "${DB_USER:-}" ] && [ -n "${DB_PASS:-}" ] && [ -n "${DB_NAME:-}" ]; then
    # External DB — passed by deploy.sh (--db=custom)
    USE_BUNDLED_PG=false
    DB_PORT=${DB_PORT:-5432}
    echo "✅ PostgreSQL: external ($DB_HOST:$DB_PORT/$DB_NAME)"
    echo "   ⚠️  Make sure the pgvector extension is available on your database!"
else
    # Bundled DB — pgvector/pgvector:pg16 in compose
    USE_BUNDLED_PG=true
    DB_USER="affine"
    DB_PASS=$(openssl rand -hex 16)
    DB_NAME="affine"
    DB_HOST="postgres"
    DB_PORT=5432
    echo "✅ PostgreSQL: bundled (pgvector/pgvector:pg16)"
fi

DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"

# =============================================================================
# DOMAIN / SERVER URL
# =============================================================================
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
    SERVER_URL="https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Caddy) — URL will be updated"
    SERVER_URL="http://localhost:$PORT"
else
    echo "⚠️  No domain - use --domain=... or access via SSH tunnel"
    SERVER_URL="http://localhost:$PORT"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# =============================================================================
# DOCKER COMPOSE
# =============================================================================
cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  affine:
    image: ghcr.io/toeverything/affine:stable
    container_name: affine_server
    restart: unless-stopped
    ports:
      - "$PORT:3010"
    depends_on:
      redis:
        condition: service_healthy
      postgres:
        condition: service_healthy
      affine_migration:
        condition: service_completed_successfully
    volumes:
      - ./storage:/root/.affine/storage
      - ./config:/root/.affine/config
    environment:
      - REDIS_SERVER_HOST=redis
      - DATABASE_URL=$DATABASE_URL
      - AFFINE_SERVER_EXTERNAL_URL=$SERVER_URL
      - AFFINE_INDEXER_ENABLED=false
    deploy:
      resources:
        limits:
          memory: 1024M

  affine_migration:
    image: ghcr.io/toeverything/affine:stable
    container_name: affine_migration_job
    volumes:
      - ./storage:/root/.affine/storage
      - ./config:/root/.affine/config
    command: ['sh', '-c', 'node ./scripts/self-host-predeploy.js']
    environment:
      - REDIS_SERVER_HOST=redis
      - DATABASE_URL=$DATABASE_URL
      - AFFINE_INDEXER_ENABLED=false
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  redis:
    image: redis:alpine
    container_name: affine_redis
    restart: unless-stopped
    healthcheck:
      test: ['CMD', 'redis-cli', '--raw', 'incr', 'ping']
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 128M

  postgres:
    image: pgvector/pgvector:pg16
    container_name: affine_postgres
    restart: unless-stopped
    volumes:
      - db-data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: $DB_USER
      POSTGRES_PASSWORD: $DB_PASS
      POSTGRES_DB: $DB_NAME
      POSTGRES_INITDB_ARGS: '--data-checksums'
    healthcheck:
      test: ['CMD', 'pg_isready', '-U', '$DB_USER', '-d', '$DB_NAME']
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 10s
    deploy:
      resources:
        limits:
          memory: 256M

volumes:
  db-data:
EOF

echo ""
echo "✅ Docker Compose generated (4 containers)"
echo "   Starting stack..."
echo ""

sudo docker compose up -d

# Health check - migration + app startup takes time
echo "⏳ Waiting for AFFiNE to start (~60-120s, database migration + app startup)..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    if ! wait_for_healthy "$APP_NAME" "$PORT" 120; then
        echo "❌ Installation failed!"
        exit 1
    fi
else
    echo "Checking if container started..."
    for i in $(seq 1 12); do
        sleep 10
        if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
            echo "✅ AFFiNE is running (after $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 12 ]; then
            echo "❌ Container failed to start within 120s!"
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

# Caddy/HTTPS - configure reverse proxy if domain is set
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ AFFiNE installed successfully!"
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
echo "📝 Create your admin account in the browser."
echo "   The first registered user becomes the workspace owner."
echo ""
if [ "${AVAILABLE_RAM:-0}" -gt 0 ] && [ "${AVAILABLE_RAM:-0}" -lt 2000 ]; then
    echo "⚠️  Your server has limited RAM (${AVAILABLE_RAM}MB free)."
    echo "   Monitor usage with: docker stats --no-stream"
    echo ""
fi
