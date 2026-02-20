#!/bin/bash

# StackPilot - Postiz
# AI-powered social media scheduling tool. Alternative to Buffer/Hootsuite.
# https://github.com/gitroomhq/postiz-app
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=3000  # ghcr.io/gitroomhq/postiz-app:v2.11.3 (1.2GB compressed → ~3GB on disk)
#
# ⚠️  NOTE: This app recommends at least 2GB RAM (2GB+ VPS)!
#     Postiz (Next.js) + Redis = ~1-1.5GB RAM
#
# Pinning v2.11.3 (pre-Temporal). Since v2.12+ Postiz requires Temporal + Elasticsearch
# + second PostgreSQL = 7 containers, minimum 4GB RAM. Too heavy for small VPS.
# https://github.com/gitroomhq/postiz-app/releases/tag/v2.11.3
#
# Required environment variables (passed by deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS - PostgreSQL database
#   DOMAIN (optional)
#   POSTIZ_REDIS (optional): auto|external|bundled (default: auto)
#   REDIS_PASS (optional): password for external Redis

set -e

APP_NAME="postiz"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-5000}

echo "--- 📱 Postiz Setup ---"
echo "AI-powered social media scheduler."
echo ""

# Port binding: always bind to 127.0.0.1 (Caddy handles public exposure)
BIND_ADDR="127.0.0.1:"

# RAM check - soft warning (don't block, just warn)
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 1800 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  NOTE: Postiz recommends at least 2GB RAM!               ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Your server: ${TOTAL_RAM}MB RAM                             ║"
    echo "║  Recommended: 2048MB RAM (2GB+ VPS)                          ║"
    echo "║                                                              ║"
    echo "║  Postiz + Redis = ~1-1.5GB RAM                               ║"
    echo "║  On a small server it may be slow.                           ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
fi

# =============================================================================
# REDIS DETECTION (external vs bundled)
# =============================================================================
# POSTIZ_REDIS=external  → use existing on host (localhost:6379)
# POSTIZ_REDIS=bundled   → always bundle redis:7.2-alpine in compose
# POSTIZ_REDIS=auto      → auto-detect (default)

source /opt/stackpilot/lib/redis-detect.sh 2>/dev/null || true
if type detect_redis &>/dev/null; then
    detect_redis "${POSTIZ_REDIS:-auto}" "postiz-redis"
else
    REDIS_HOST="postiz-redis"
    echo "✅ Redis: bundled (lib/redis-detect.sh unavailable)"
fi

# Redis password (user provides via REDIS_PASS env var)
REDIS_PASS="${REDIS_PASS:-}"
if [ -n "$REDIS_PASS" ] && [ "$REDIS_HOST" = "host-gateway" ]; then
    echo "   🔑 Redis password: set"
fi

# Build REDIS_URL
if [ "$REDIS_HOST" = "host-gateway" ]; then
    if [ -n "$REDIS_PASS" ]; then
        REDIS_URL="redis://:${REDIS_PASS}@host-gateway:6379"
    else
        REDIS_URL="redis://host-gateway:6379"
    fi
else
    REDIS_URL="redis://postiz-redis:6379"
fi

# Check PostgreSQL credentials
if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
    echo "❌ Missing PostgreSQL credentials!"
    echo "   Required: DB_HOST, DB_USER, DB_PASS, DB_NAME"
    echo ""
    echo "   Use deploy.sh - it will configure the database automatically:"
    echo "   ./local/deploy.sh postiz --ssh=mikrus"
    exit 1
fi

DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-postiz}

echo "✅ PostgreSQL: $DB_HOST:$DB_PORT/$DB_NAME (user: $DB_USER)"

# Build DATABASE_URL
DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"

# Generate secrets
JWT_SECRET=$(openssl rand -hex 32)

# Domain / URLs
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
    MAIN_URL="https://$DOMAIN"
    FRONTEND_URL="https://$DOMAIN"
    BACKEND_URL="https://$DOMAIN/api"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Caddy) — URLs will be updated"
    MAIN_URL="http://localhost:$PORT"
    FRONTEND_URL="http://localhost:$PORT"
    BACKEND_URL="http://localhost:$PORT/api"
else
    echo "⚠️  No domain - use --domain=... or access via SSH tunnel"
    MAIN_URL="http://localhost:$PORT"
    FRONTEND_URL="http://localhost:$PORT"
    BACKEND_URL="http://localhost:$PORT/api"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# --- Docker Compose: conditional Redis blocks ---
POSTIZ_DEPENDS=""
POSTIZ_EXTRA_HOSTS=""
REDIS_SERVICE=""

if [ "$REDIS_HOST" = "postiz-redis" ]; then
    # Bundled Redis
    POSTIZ_DEPENDS="    depends_on:
      postiz-redis:
        condition: service_healthy"
    REDIS_SERVICE="
  postiz-redis:
    image: redis:7.2-alpine
    restart: always
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - ./redis-data:/data
    healthcheck:
      test: [\"CMD\", \"redis-cli\", \"ping\"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 128M"
else
    # External Redis - connect to host
    POSTIZ_EXTRA_HOSTS="    extra_hosts:
      - \"host-gateway:host-gateway\""
fi

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  postiz:
    image: ghcr.io/gitroomhq/postiz-app:v2.11.3
    restart: always
    ports:
      - "${BIND_ADDR}$PORT:5000"
    environment:
      - MAIN_URL=$MAIN_URL
      - FRONTEND_URL=$FRONTEND_URL
      - NEXT_PUBLIC_BACKEND_URL=$BACKEND_URL
      - BACKEND_INTERNAL_URL=http://localhost:3000
      - DATABASE_URL=$DATABASE_URL
      - REDIS_URL=$REDIS_URL
      - JWT_SECRET=$JWT_SECRET
      - IS_GENERAL=true
      - STORAGE_PROVIDER=local
      - UPLOAD_DIRECTORY=/uploads
      - NEXT_PUBLIC_UPLOAD_DIRECTORY=/uploads
      - NX_ADD_PLUGINS=false
    volumes:
      - ./config:/config
      - ./uploads:/uploads
$POSTIZ_DEPENDS
$POSTIZ_EXTRA_HOSTS
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: 1024M
$REDIS_SERVICE
EOF

sudo docker compose up -d

# Health check - Next.js needs ~60-90s to start
echo "⏳ Waiting for Postiz to start (~60-90s, Next.js)..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 90 || { echo "❌ Installation failed!"; exit 1; }
else
    for i in $(seq 1 9); do
        sleep 10
        if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
            echo "✅ Postiz is running (after $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 9 ]; then
            echo "❌ Container failed to start within 90s!"
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ Postiz installed!"
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
echo "   2. Connect social media accounts (Twitter/X, LinkedIn, Instagram...)"
echo "   3. Schedule your first posts!"
echo ""
echo "🔒 After creating your account, disable registration:"
echo "   ssh <server> 'cd $STACK_DIR && grep -q DISABLE_REGISTRATION docker-compose.yaml || sed -i \"/IS_GENERAL/a\\      - DISABLE_REGISTRATION=true\" docker-compose.yaml && docker compose up -d'"
