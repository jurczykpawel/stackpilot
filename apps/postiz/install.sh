#!/bin/bash

# StackPilot - Postiz
# AI-powered social media scheduling tool. Alternative to Buffer/Hootsuite.
# https://github.com/gitroomhq/postiz-app
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=5000  # Postiz + Temporal + Elasticsearch + 2x PostgreSQL + Redis
#
# ⚠️  NOTE: Postiz requires a DEDICATED server (min. 4GB RAM)!
#     Postiz (Next.js + Nest.js + nginx + workers + cron) = ~1-1.5GB
#     Temporal + Elasticsearch + PostgreSQL = ~1-1.5GB
#     Total: ~2.5-3GB RAM
#     Do not install alongside other heavy services!
#
# Stack: 7 containers
#   - postiz (application)
#   - postiz-postgres (Postiz database)
#   - postiz-redis (cache + queues)
#   - temporal (workflow engine)
#   - temporal-elasticsearch (Temporal search)
#   - temporal-postgresql (Temporal database)
#   - temporal-ui (Temporal panel, optional)
#
# PostgreSQL database:
#   Bundled by default (postgres:17-alpine in compose).
#   If deploy.sh passes DB_HOST/DB_USER/DB_PASS — uses external DB.
#
# Required environment variables (passed by deploy.sh):
#   DOMAIN (optional)
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS (optional — if external DB)

set -e

APP_NAME="postiz"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-5000}

echo "--- 📱 Postiz Setup ---"
echo "AI-powered social media scheduler (latest + Temporal)."
echo ""

# Port binding: always bind to 127.0.0.1 (Caddy handles public exposure)
BIND_ADDR="127.0.0.1:"

# RAM check - Postiz with Temporal needs ~3GB
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 3500 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  NOTE: Postiz + Temporal recommends at least 4GB RAM!    ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Your server: ${TOTAL_RAM}MB RAM                             ║"
    echo "║  Recommended: 4096MB RAM (4GB+ VPS)                          ║"
    echo "║                                                              ║"
    echo "║  Postiz + Temporal + ES + 2x PG + Redis = ~2.5-3GB RAM      ║"
    echo "║  On a server <4GB there may be stability issues.             ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
fi

# =============================================================================
# DATABASE — BUNDLED vs EXTERNAL
# =============================================================================
JWT_SECRET=$(openssl rand -hex 32)

if [ -n "${DB_HOST:-}" ] && [ -n "${DB_USER:-}" ] && [ -n "${DB_PASS:-}" ]; then
    # External DB — passed by deploy.sh (--db=custom)
    USE_BUNDLED_PG=false
    DB_PORT=${DB_PORT:-5432}
    DB_NAME=${DB_NAME:-postiz}
    DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"
    echo "✅ PostgreSQL: external ($DB_HOST:$DB_PORT/$DB_NAME)"
else
    # Bundled DB — postgres:17-alpine in compose
    USE_BUNDLED_PG=true
    PG_POSTIZ_PASS=$(openssl rand -hex 16)
    DATABASE_URL="postgresql://postiz:${PG_POSTIZ_PASS}@postiz-postgres:5432/postiz"
    echo "✅ PostgreSQL: bundled (postgres:17-alpine)"
fi

# =============================================================================
# REDIS — BUNDLED vs EXTERNAL (auto-detection)
# =============================================================================
source /opt/stackpilot/lib/redis-detect.sh 2>/dev/null || true
if type detect_redis &>/dev/null; then
    detect_redis "${POSTIZ_REDIS:-auto}" "postiz-redis"
else
    REDIS_HOST="postiz-redis"
    echo "✅ Redis: bundled (lib/redis-detect.sh unavailable)"
fi

REDIS_PASS="${REDIS_PASS:-}"
if [ "$REDIS_HOST" = "host-gateway" ]; then
    USE_BUNDLED_REDIS=false
    if [ -n "$REDIS_PASS" ]; then
        REDIS_URL="redis://:${REDIS_PASS}@host-gateway:6379"
    else
        REDIS_URL="redis://host-gateway:6379"
    fi
else
    USE_BUNDLED_REDIS=true
    REDIS_URL="redis://postiz-redis:6379"
fi

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

# =============================================================================
# .env FILE — OFFICIAL TEMPLATE FROM POSTIZ REPOSITORY
# =============================================================================
# Download .env.example only on first install (don't overwrite user-configured keys)
if [ ! -f .env ]; then
    ENV_URL="https://raw.githubusercontent.com/gitroomhq/postiz-app/main/.env.example"
    if curl -sf "$ENV_URL" -o /tmp/postiz-env-example 2>/dev/null; then
        # Add header with instructions
        {
            echo "# ╔════════════════════════════════════════════════════════════════╗"
            echo "# ║  Postiz — social media platform API keys                      ║"
            echo "# ║  Fill in only the platforms you want to use.                   ║"
            echo "# ║  Docs: https://docs.postiz.com/providers                      ║"
            echo "# ╚════════════════════════════════════════════════════════════════╝"
            echo ""
            cat /tmp/postiz-env-example
        } | sudo tee .env > /dev/null
        rm -f /tmp/postiz-env-example
        sudo chmod 600 .env
        echo "✅ .env file downloaded from Postiz repository: $STACK_DIR/.env"
    else
        echo "⚠️  Could not download .env.example — create the file manually"
        echo "   $ENV_URL"
    fi
else
    echo "✅ .env file already exists — not overwriting"
fi

# =============================================================================
# TEMPORAL DYNAMIC CONFIG
# =============================================================================
sudo mkdir -p "$STACK_DIR/dynamicconfig"
cat <<'DYNEOF' | sudo tee "$STACK_DIR/dynamicconfig/development-sql.yaml" > /dev/null
limit.maxIDLength:
  - value: 255
    constraints: {}
system.forceSearchAttributesCacheRefreshOnRead:
  - value: true
    constraints: {}
DYNEOF

# =============================================================================
# DOCKER COMPOSE — FULL STACK WITH TEMPORAL
# =============================================================================

# Conditional blocks: bundled vs external PostgreSQL / Redis
POSTIZ_DEPENDS_LIST=""
POSTIZ_EXTRA_HOSTS=""
POSTIZ_PG_SERVICE=""
POSTIZ_REDIS_SERVICE=""

if [ "$USE_BUNDLED_PG" = true ]; then
    POSTIZ_DEPENDS_LIST="${POSTIZ_DEPENDS_LIST}
      postiz-postgres:
        condition: service_healthy"
    POSTIZ_PG_SERVICE="
  # --- PostgreSQL (Postiz database) ---
  postiz-postgres:
    image: postgres:17-alpine
    restart: always
    environment:
      - POSTGRES_USER=postiz
      - POSTGRES_PASSWORD=${PG_POSTIZ_PASS}
      - POSTGRES_DB=postiz
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    networks:
      - postiz-network
    healthcheck:
      test: [\"CMD\", \"pg_isready\", \"-U\", \"postiz\", \"-d\", \"postiz\"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 256M"
fi

if [ "$USE_BUNDLED_REDIS" = true ]; then
    POSTIZ_DEPENDS_LIST="${POSTIZ_DEPENDS_LIST}
      postiz-redis:
        condition: service_healthy"
    POSTIZ_REDIS_SERVICE="
  # --- Redis ---
  postiz-redis:
    image: redis:7.2-alpine
    restart: always
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - ./redis-data:/data
    networks:
      - postiz-network
    healthcheck:
      test: [\"CMD\", \"redis-cli\", \"ping\"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 128M"
fi

# Extra hosts for external DB/Redis
if [ "$USE_BUNDLED_PG" = false ] || [ "$USE_BUNDLED_REDIS" = false ]; then
    POSTIZ_EXTRA_HOSTS="    extra_hosts:
      - \"host-gateway:host-gateway\""
fi

# Build depends_on
if [ -n "$POSTIZ_DEPENDS_LIST" ]; then
    POSTIZ_DEPENDS="    depends_on:${POSTIZ_DEPENDS_LIST}"
else
    POSTIZ_DEPENDS=""
fi

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  # --- Postiz (main application) ---
  postiz:
    image: ghcr.io/gitroomhq/postiz-app:latest
    restart: always
    env_file: .env
    ports:
      - "${BIND_ADDR}$PORT:5000"
    environment:
      - MAIN_URL=$MAIN_URL
      - FRONTEND_URL=$FRONTEND_URL
      - NEXT_PUBLIC_BACKEND_URL=$BACKEND_URL
      - BACKEND_INTERNAL_URL=http://localhost:3000
      - DATABASE_URL=$DATABASE_URL
      - REDIS_URL=$REDIS_URL
      - TEMPORAL_ADDRESS=temporal:7233
      - JWT_SECRET=$JWT_SECRET
      - IS_GENERAL=true
      - STORAGE_PROVIDER=local
      - UPLOAD_DIRECTORY=/uploads
      - NEXT_PUBLIC_UPLOAD_DIRECTORY=/uploads
      - NX_ADD_PLUGINS=false
    volumes:
      - ./config:/config
      - ./uploads:/uploads
    networks:
      - postiz-network
      - temporal-network
$POSTIZ_DEPENDS
$POSTIZ_EXTRA_HOSTS
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s
    deploy:
      resources:
        limits:
          memory: 1536M
$POSTIZ_PG_SERVICE
$POSTIZ_REDIS_SERVICE

  # --- Temporal (workflow engine) ---
  temporal:
    image: temporalio/auto-setup:1.28.1
    restart: always
    depends_on:
      - temporal-postgresql
      - temporal-elasticsearch
    environment:
      - DB=postgres12
      - DB_PORT=5432
      - POSTGRES_USER=temporal
      - POSTGRES_PWD=temporal
      - POSTGRES_SEEDS=temporal-postgresql
      - DYNAMIC_CONFIG_FILE_PATH=config/dynamicconfig/development-sql.yaml
      - ENABLE_ES=true
      - ES_SEEDS=temporal-elasticsearch
      - ES_VERSION=v7
      - TEMPORAL_NAMESPACE=default
    networks:
      - temporal-network
    volumes:
      - ./dynamicconfig:/etc/temporal/config/dynamicconfig
    deploy:
      resources:
        limits:
          memory: 512M

  # --- Elasticsearch (required by Temporal) ---
  temporal-elasticsearch:
    image: elasticsearch:7.17.27
    restart: always
    environment:
      - cluster.routing.allocation.disk.threshold_enabled=true
      - cluster.routing.allocation.disk.watermark.low=512mb
      - cluster.routing.allocation.disk.watermark.high=256mb
      - cluster.routing.allocation.disk.watermark.flood_stage=128mb
      - discovery.type=single-node
      - ES_JAVA_OPTS=-Xms256m -Xmx256m
      - xpack.security.enabled=false
    networks:
      - temporal-network
    deploy:
      resources:
        limits:
          memory: 512M

  # --- PostgreSQL (Temporal database) ---
  temporal-postgresql:
    image: postgres:16-alpine
    restart: always
    environment:
      - POSTGRES_USER=temporal
      - POSTGRES_PASSWORD=temporal
    volumes:
      - ./temporal-postgres-data:/var/lib/postgresql/data
    networks:
      - temporal-network
    deploy:
      resources:
        limits:
          memory: 128M

  # --- Temporal UI (workflow management panel) ---
  temporal-ui:
    image: temporalio/ui:2.34.0
    restart: always
    environment:
      - TEMPORAL_ADDRESS=temporal:7233
      - TEMPORAL_CORS_ORIGINS=http://127.0.0.1:3000
    networks:
      - temporal-network
    ports:
      - "127.0.0.1:8080:8080"
    depends_on:
      - temporal
    deploy:
      resources:
        limits:
          memory: 128M

networks:
  postiz-network:
  temporal-network:
EOF

# Append bundled database service if using bundled DB (from deploy.sh)
if [ -n "$BUNDLED_DB_TYPE" ]; then
    # Add depends_on to main service
    sudo sed -i '/restart: always/a\    depends_on:\n      - db' docker-compose.yaml

    if [ "$BUNDLED_DB_TYPE" = "postgres" ]; then
        cat <<DBEOF | sudo tee -a docker-compose.yaml > /dev/null
  db:
    image: postgres:16-alpine
    restart: always
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - db-data:/var/lib/postgresql/data
    deploy:
      resources:
        limits:
          memory: 256M

volumes:
  db-data:
DBEOF
    fi
fi

# Count containers
CONTAINER_COUNT=5  # postiz + temporal + temporal-es + temporal-pg + temporal-ui
[ "$USE_BUNDLED_PG" = true ] && CONTAINER_COUNT=$((CONTAINER_COUNT + 1))
[ "$USE_BUNDLED_REDIS" = true ] && CONTAINER_COUNT=$((CONTAINER_COUNT + 1))

echo ""
echo "✅ Docker Compose generated ($CONTAINER_COUNT containers)"
echo "   Starting stack..."
echo ""

sudo docker compose up -d

# Health check - Temporal + Postiz need more time to start
echo "⏳ Waiting for Postiz to start (~90-120s, Temporal + Next.js)..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 120 || { echo "❌ Installation failed!"; exit 1; }
else
    for i in $(seq 1 12); do
        sleep 10
        if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
            echo "✅ Postiz is running (after $((i*10))s)"
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

# =============================================================================
# UPLOAD VERIFICATION (required for TikTok, Instagram media)
# =============================================================================
UPLOADS_OK=false
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    for i in $(seq 1 6); do
        UPLOAD_CHECK=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${DOMAIN}/uploads/" 2>/dev/null || echo "000")
        if [ "$UPLOAD_CHECK" -ge 200 ] && [ "$UPLOAD_CHECK" -lt 500 ]; then
            UPLOADS_OK=true
            break
        fi
        sleep 5
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

if [ "$UPLOADS_OK" = true ]; then
    echo ""
    echo -e "${GREEN:-\033[0;32m}✅ Public uploads: https://${DOMAIN}/uploads/${NC:-\033[0m}"
    echo "   TikTok, Instagram and other platforms requiring pull_from_url will work."
else
    echo ""
    echo -e "${YELLOW:-\033[1;33m}⚠️  Uploads may not be publicly accessible!${NC:-\033[0m}"
    echo "   TikTok fetches media via URL — files must be accessible over HTTPS."
    echo "   Check: https://<your-domain>/uploads/"
    echo "   Alternative: Cloudflare R2 (STORAGE_PROVIDER=cloudflare-r2)"
fi

echo ""
echo "📝 Next steps:"
echo "   1. Create an admin account in the browser"
echo "   2. Disable registration (command below!)"
echo "   3. Fill in API keys in the .env file:"
echo ""
echo "      ssh ${SSH_ALIAS:-vps} 'nano $STACK_DIR/.env'"
echo ""
echo "      Fill in KEY/SECRET pairs only for platforms you use."
echo "      After saving: ssh ${SSH_ALIAS:-vps} 'cd $STACK_DIR && docker compose up -d'"
echo "      Docs: https://docs.postiz.com/providers"
echo ""
echo "   ⚠️  Important notes when configuring providers:"
echo "   • Facebook: switch app from Development → Live (otherwise posts visible only to you!)"
echo "   • LinkedIn: add Advertising API (without it tokens won't refresh!)"
echo "   • TikTok: domain with uploads must be verified in TikTok Developer Account"
echo "   • YouTube: after configuring Brand Account wait ~5h for propagation"
echo "   • Threads: complex configuration — read docs.postiz.com/providers/threads"
echo "   • Discord/Slack: app icon is required (without it you get 404 error)"
echo ""
echo "🔒 IMPORTANT — disable registration after creating your account:"
echo "   ssh ${SSH_ALIAS:-vps} 'cd $STACK_DIR && sed -i \"/IS_GENERAL/a\\\\      - DISABLE_REGISTRATION=true\" docker-compose.yaml && docker compose up -d'"
