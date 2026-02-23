#!/bin/bash

# Mikrus Toolbox - Subtitle Burner
# Twórz, styluj i wypalaj animowane napisy na wideo.
# Edytor wizualny, 8 szablonów, transkrypcja AI, server-side rendering (FFmpeg).
# https://github.com/jurczykpawel/subtitle-burner
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=900  # Next.js + Bun + FFmpeg + Nginx + MinIO (+ opcjonalnie PG/Redis)
#
# ⚠️  UWAGA: Ta aplikacja wymaga minimum 2GB RAM (Mikrus 3.0+)!
#     Kontenery: web, worker (FFmpeg), nginx, minio + opcjonalnie postgres/redis.
#     Na Mikrus 2.1 (1GB RAM) nie uruchomi się poprawnie.
#
# Stack: Next.js (Bun) + BullMQ Worker (FFmpeg) + PostgreSQL 16 + Redis 7 + MinIO + Nginx
#
# Zmienne środowiskowe (przekazywane przez deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS - zewnętrzna baza (opcjonalne)
#   BUNDLED_DB_TYPE - "postgres" jeśli deploy.sh bundluje bazę
#   DOMAIN - domena (opcjonalne)

set -e

APP_NAME="subtitle-burner"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}
REPO_URL="https://github.com/jurczykpawel/subtitle-burner.git"

echo "--- 🎬 Subtitle Burner Setup ---"
echo "Wypalaj animowane napisy na wideo."
echo ""

# Port binding: Cytrus wymaga 0.0.0.0, Cloudflare/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

# Sprawdź dostępny RAM - WYMAGANE minimum 2GB!
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 1800 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ BŁĄD: Za mało RAM dla Subtitle Burner!                   ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Twój serwer: ${TOTAL_RAM}MB RAM                             ║"
    echo "║  Wymagane:    2048MB RAM (Mikrus 3.0+)                       ║"
    echo "║                                                              ║"
    echo "║  Kontenery: web, worker (FFmpeg), nginx, minio + PG/Redis.   ║"
    echo "║  Na Mikrus 2.1 nie uruchomi się poprawnie!                   ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# =============================================================================
# 1. BAZA DANYCH (PostgreSQL - external lub bundled)
# =============================================================================
DB_PORT=${DB_PORT:-5432}

if [ -n "$DB_HOST" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASS" ] && [ -n "$DB_NAME" ]; then
    echo "✅ PostgreSQL: zewnętrzna ($DB_HOST:$DB_PORT/$DB_NAME)"
    DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    PG_PASS="$DB_PASS"
    PG_USER="$DB_USER"
    PG_DB="$DB_NAME"
    USE_BUNDLED_PG=false
else
    echo "✅ PostgreSQL: bundled (kontener)"
    PG_PASS=$(openssl rand -hex 16)
    PG_USER="subtitle_burner"
    PG_DB="subtitle_burner"
    DATABASE_URL="postgresql://${PG_USER}:${PG_PASS}@postgres:5432/${PG_DB}"
    USE_BUNDLED_PG=true
fi

# =============================================================================
# 2. REDIS (external vs bundled via redis-detect.sh)
# =============================================================================
source /opt/mikrus-toolbox/lib/redis-detect.sh 2>/dev/null || true
if type detect_redis &>/dev/null; then
    detect_redis "auto" "redis"
else
    REDIS_HOST="redis"
    echo "✅ Redis: bundled (lib/redis-detect.sh niedostępne)"
fi

# Shared Redis: jeśli bundled wybrany, użyj redis-shared
if [ "$REDIS_HOST" = "redis" ]; then
    REDIS_SHARED_DIR="/opt/stacks/redis-shared"
    if [ ! -f "$REDIS_SHARED_DIR/docker-compose.yaml" ]; then
        echo "📦 Instaluję współdzielony Redis..."
        sudo mkdir -p "$REDIS_SHARED_DIR"
        cat <<'REDISEOF' | sudo tee "$REDIS_SHARED_DIR/docker-compose.yaml" > /dev/null
services:
  redis:
    image: redis:alpine
    restart: always
    ports:
      - "6379:6379"
    command: redis-server --maxmemory 96mb --maxmemory-policy allkeys-lru --save 60 1 --loglevel warning
    volumes:
      - ./data:/data
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "2"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 128M
REDISEOF
        sudo docker compose -f "$REDIS_SHARED_DIR/docker-compose.yaml" up -d
        sleep 2
    fi
    REDIS_HOST="host-gateway"
    echo "✅ Redis: współdzielony (127.0.0.1:6379)"
fi

# Redis URL dla Subtitle Burner
if [ "$REDIS_HOST" = "host-gateway" ]; then
    REDIS_URL="redis://host.docker.internal:6379"
else
    REDIS_URL="redis://${REDIS_HOST}:6379"
fi

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domena: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domena: automatyczna (Cytrus)"
else
    echo "⚠️  Brak domeny - użyj --domain=... lub dostęp przez SSH tunnel"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Klonuj lub aktualizuj repozytorium
if [ -d "$STACK_DIR/repo/.git" ]; then
    echo "📦 Aktualizuję repozytorium..."
    cd "$STACK_DIR/repo"
    sudo git pull --quiet
    cd "$STACK_DIR"
else
    echo "📦 Klonuję repozytorium..."
    sudo git clone --depth 1 "$REPO_URL" "$STACK_DIR/repo"
fi

# Generuj sekrety
AUTH_SECRET=$(openssl rand -base64 32)
MINIO_ACCESS=$(openssl rand -hex 12)
MINIO_SECRET=$(openssl rand -hex 24)

# URL aplikacji
APP_URL="http://localhost:$PORT"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    APP_URL="https://$DOMAIN"
fi

# Generuj .env
cat <<EOF | sudo tee .env > /dev/null
# App
AUTH_SECRET=$AUTH_SECRET
NEXT_PUBLIC_APP_URL=$APP_URL
NODE_ENV=production

# PostgreSQL
POSTGRES_USER=$PG_USER
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DB=$PG_DB
POSTGRES_PORT=$DB_PORT
DATABASE_URL=$DATABASE_URL

# Redis
REDIS_PORT=6379
REDIS_URL=$REDIS_URL

# MinIO (object storage)
MINIO_ENDPOINT=minio
MINIO_PORT=9000
MINIO_CONSOLE_PORT=9001
MINIO_ACCESS_KEY=$MINIO_ACCESS
MINIO_SECRET_KEY=$MINIO_SECRET
MINIO_BUCKET=subtitle-burner
MINIO_USE_SSL=false

# Email (opcjonalnie - do magic links)
# SMTP_HOST=smtp.resend.com
# SMTP_PORT=587
# SMTP_USER=resend
# SMTP_PASS=re_xxxxx
# EMAIL_FROM=noreply@yourdomain.com
EOF

sudo chmod 600 .env
echo "✅ Konfiguracja wygenerowana"

# Nginx config (z repo)
sudo cp "$STACK_DIR/repo/docker/nginx.conf" "$STACK_DIR/nginx.conf" 2>/dev/null || true

# =============================================================================
# GENERUJ docker-compose.yaml
# =============================================================================
cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  nginx:
    image: nginx:alpine
    restart: always
    ports:
      - "${BIND_ADDR}${PORT}:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      web:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 64M

  web:
    build:
      context: ./repo
      dockerfile: docker/Dockerfile
    env_file: .env
    restart: always
EOF

# depends_on dla web
if [ "$USE_BUNDLED_PG" = true ]; then
cat <<EOF | sudo tee -a docker-compose.yaml > /dev/null
    depends_on:
      postgres:
        condition: service_healthy
      minio:
        condition: service_healthy
EOF
else
cat <<EOF | sudo tee -a docker-compose.yaml > /dev/null
    depends_on:
      minio:
        condition: service_healthy
EOF
fi

# Extra hosts (dla host-gateway Redis)
if [ "$REDIS_HOST" = "host-gateway" ]; then
cat <<EOF | sudo tee -a docker-compose.yaml > /dev/null
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF
fi

cat <<EOF | sudo tee -a docker-compose.yaml > /dev/null
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: 512M

  worker:
    build:
      context: ./repo
      dockerfile: docker/Dockerfile.worker
    env_file: .env
    restart: always
EOF

# Extra hosts dla worker
if [ "$REDIS_HOST" = "host-gateway" ]; then
cat <<EOF | sudo tee -a docker-compose.yaml > /dev/null
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF
fi

cat <<EOF | sudo tee -a docker-compose.yaml > /dev/null
    deploy:
      resources:
        limits:
          memory: 512M

  minio:
    image: minio/minio
    command: server /data --console-address ":9001"
    restart: always
    environment:
      MINIO_ROOT_USER: $MINIO_ACCESS
      MINIO_ROOT_PASSWORD: $MINIO_SECRET
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 256M

EOF

# Bundled PostgreSQL (jeśli nie external)
if [ "$USE_BUNDLED_PG" = true ]; then
cat <<EOF | sudo tee -a docker-compose.yaml > /dev/null
  postgres:
    image: postgres:16-alpine
    restart: always
    environment:
      POSTGRES_USER: $PG_USER
      POSTGRES_PASSWORD: $PG_PASS
      POSTGRES_DB: $PG_DB
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $PG_USER"]
      interval: 5s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 256M

EOF
fi

# Volumes
cat <<EOF | sudo tee -a docker-compose.yaml > /dev/null
volumes:
  minio_data:
EOF

if [ "$USE_BUNDLED_PG" = true ]; then
cat <<EOF | sudo tee -a docker-compose.yaml > /dev/null
  postgres_data:
EOF
fi

# Buduj i uruchamiaj
echo "🔨 Buduję obrazy Docker (to może potrwać kilka minut)..."
sudo docker compose build --quiet 2>/dev/null || sudo docker compose build

# Start bundled DB first
if [ "$USE_BUNDLED_PG" = true ]; then
    sudo docker compose up -d postgres
    echo "⏳ Czekam na PostgreSQL..."
    for i in $(seq 1 12); do
        if sudo docker compose exec -T postgres pg_isready -U "$PG_USER" > /dev/null 2>&1; then
            break
        fi
        sleep 5
    done
fi

sudo docker compose up -d

# Migracje bazy danych
echo "📦 Uruchamiam migracje bazy danych..."
sleep 5
sudo docker compose exec -T web ./node_modules/.bin/prisma migrate deploy --schema=/app/packages/database/prisma/schema.prisma || {
    echo "⚠️  Migracje nie powiodły się (pierwszy start może wymagać retry)."
    echo "   Spróbuj ręcznie: cd $STACK_DIR && sudo docker compose exec web ./node_modules/.bin/prisma migrate deploy --schema=/app/packages/database/prisma/schema.prisma"
}

# Health check
echo "⏳ Czekam na uruchomienie (~30-60s)..."
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 90 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    for i in $(seq 1 9); do
        sleep 10
        if curl -sf "http://localhost:$PORT/" > /dev/null 2>&1; then
            echo "✅ Subtitle Burner działa (po $((i*10))s)"
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
echo "✅ Subtitle Burner zainstalowany!"
echo "════════════════════════════════════════════════════════════════"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Aplikacja:  https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Dostęp przez SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
    echo "   http://localhost:$PORT"
fi
echo ""
if [ "$USE_BUNDLED_PG" = true ]; then
    echo "   Baza: PostgreSQL bundled (kontener)"
else
    echo "   Baza: PostgreSQL external ($DB_HOST:$DB_PORT/$DB_NAME)"
fi
echo "   Redis: $REDIS_HOST"
echo ""
echo "🔑 Sekrety zapisane w: $STACK_DIR/.env"
echo ""
echo "📋 Następne kroki:"
echo "   1. Otwórz aplikację i zarejestruj konto"
echo "   2. (Opcjonalnie) Skonfiguruj SMTP w .env → magic link auth"
echo "   3. Wgraj wideo i przetestuj wypalanie napisów"
