#!/bin/bash

# Mikrus Toolbox - Postiz
# AI-powered social media scheduling tool. Alternative to Buffer/Hootsuite.
# https://github.com/gitroomhq/postiz-app
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=3000  # ghcr.io/gitroomhq/postiz-app:v2.11.3 (1.2GB compressed → ~3GB on disk)
#
# ⚠️  UWAGA: Ta aplikacja zaleca minimum 2GB RAM (Mikrus 3.0+)!
#     Postiz (Next.js) + Redis = ~1-1.5GB RAM
#
# Pinujemy v2.11.3 (pre-Temporal). Od v2.12+ Postiz wymaga Temporal + Elasticsearch
# + drugi PostgreSQL = 7 kontenerów, minimum 4GB RAM. Zbyt ciężkie na Mikrus.
# https://github.com/gitroomhq/postiz-app/releases/tag/v2.11.3
#
# Wymagane zmienne środowiskowe (przekazywane przez deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS - baza PostgreSQL
#   DOMAIN (opcjonalne)
#   POSTIZ_REDIS (opcjonalne): auto|external|bundled (domyślnie: auto)
#   REDIS_PASS (opcjonalne): hasło do external Redis

set -e

APP_NAME="postiz"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-5000}

echo "--- 📱 Postiz Setup ---"
echo "AI-powered social media scheduler."
echo ""

# Port binding: Cytrus wymaga 0.0.0.0, Cloudflare/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

# RAM check - soft warning (nie blokujemy, ale ostrzegamy)
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 1800 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  UWAGA: Postiz zaleca minimum 2GB RAM!                   ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Twój serwer: ${TOTAL_RAM}MB RAM                             ║"
    echo "║  Zalecane:    2048MB RAM (Mikrus 3.0+)                       ║"
    echo "║                                                              ║"
    echo "║  Postiz + Redis = ~1-1.5GB RAM                               ║"
    echo "║  Na małym serwerze może być wolny.                           ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
fi

# =============================================================================
# DETEKCJA REDIS (external vs bundled)
# =============================================================================
# POSTIZ_REDIS=external  → użyj istniejącego na hoście (localhost:6379)
# POSTIZ_REDIS=bundled   → zawsze bundluj redis:7.2-alpine w compose
# POSTIZ_REDIS=auto      → auto-detekcja (domyślne)

source /opt/mikrus-toolbox/lib/redis-detect.sh 2>/dev/null || true
if type detect_redis &>/dev/null; then
    detect_redis "${POSTIZ_REDIS:-auto}" "postiz-redis"
else
    REDIS_HOST="postiz-redis"
    echo "✅ Redis: bundled (lib/redis-detect.sh niedostępne)"
fi

# Hasło Redis (user podaje przez REDIS_PASS env var)
REDIS_PASS="${REDIS_PASS:-}"
if [ -n "$REDIS_PASS" ] && [ "$REDIS_HOST" = "host-gateway" ]; then
    echo "   🔑 Hasło Redis: ustawione"
fi

# Buduj REDIS_URL
if [ "$REDIS_HOST" = "host-gateway" ]; then
    if [ -n "$REDIS_PASS" ]; then
        REDIS_URL="redis://:${REDIS_PASS}@host-gateway:6379"
    else
        REDIS_URL="redis://host-gateway:6379"
    fi
else
    REDIS_URL="redis://postiz-redis:6379"
fi

# Check for shared Mikrus DB (doesn't support gen_random_uuid on PG 12)
if [[ "$DB_HOST" == psql*.mikr.us ]]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ BŁĄD: Postiz NIE działa ze współdzieloną bazą Mikrusa!    ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Postiz (Prisma) wymaga gen_random_uuid(), które nie jest      ║"
    echo "║  dostępne w PostgreSQL 12 (shared Mikrus).                     ║"
    echo "║                                                                ║"
    echo "║  Rozwiązanie: Kup dedykowany PostgreSQL                        ║"
    echo "║  https://mikr.us/panel/?a=cloud                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# Sprawdź dane bazy PostgreSQL
if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
    echo "❌ Brak danych bazy PostgreSQL!"
    echo "   Wymagane: DB_HOST, DB_USER, DB_PASS, DB_NAME"
    echo ""
    echo "   Użyj deploy.sh - automatycznie skonfiguruje bazę:"
    echo "   ./local/deploy.sh postiz --ssh=mikrus"
    exit 1
fi

DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-postiz}

echo "✅ Baza PostgreSQL: $DB_HOST:$DB_PORT/$DB_NAME (user: $DB_USER)"

# Buduj DATABASE_URL
DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"

# Generuj sekrety
JWT_SECRET=$(openssl rand -hex 32)

# Domain / URLs
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domena: $DOMAIN"
    MAIN_URL="https://$DOMAIN"
    FRONTEND_URL="https://$DOMAIN"
    BACKEND_URL="https://$DOMAIN/api"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domena: automatyczna (Cytrus) — URL-e zostaną zaktualizowane"
    MAIN_URL="http://localhost:$PORT"
    FRONTEND_URL="http://localhost:$PORT"
    BACKEND_URL="http://localhost:$PORT/api"
else
    echo "⚠️  Brak domeny - użyj --domain=... lub dostęp przez SSH tunnel"
    MAIN_URL="http://localhost:$PORT"
    FRONTEND_URL="http://localhost:$PORT"
    BACKEND_URL="http://localhost:$PORT/api"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# --- Docker Compose: warunkowe bloki Redis ---
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
    # External Redis - łącz z hostem
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

# Health check - Next.js potrzebuje ~60-90s na start
echo "⏳ Czekam na uruchomienie Postiz (~60-90s, Next.js)..."
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 90 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    for i in $(seq 1 9); do
        sleep 10
        if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
            echo "✅ Postiz działa (po $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 9 ]; then
            echo "❌ Kontener nie wystartował w 90s!"
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ Postiz zainstalowany!"
echo "════════════════════════════════════════════════════════════════"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Otwórz https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Dostęp przez SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo ""
echo "📝 Następne kroki:"
echo "   1. Utwórz konto administratora w przeglądarce"
echo "   2. Podłącz konta social media (Twitter/X, LinkedIn, Instagram...)"
echo "   3. Zaplanuj pierwsze posty!"
echo ""
echo "🔒 Po utworzeniu konta wyłącz rejestrację:"
echo "   ssh <server> 'cd $STACK_DIR && grep -q DISABLE_REGISTRATION docker-compose.yaml || sed -i \"/IS_GENERAL/a\\      - DISABLE_REGISTRATION=true\" docker-compose.yaml && docker compose up -d'"
