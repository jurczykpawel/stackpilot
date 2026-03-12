#!/bin/bash

# StackPilot - RoutePix
# Wizualizuj trasy podróży ze zdjęć geotagowanych.
# Upload zdjęć → EXIF → mapa z markerami i trasą. AI rozpoznaje sceny.
# https://github.com/jurczykpawel/routepix
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=600  # Node.js 22 + Next.js standalone + better-sqlite3 + vips
# DB_BUNDLED=true  # SQLite embedded in container — no external database needed
#
# Stack: Next.js 16 + Prisma + SQLite + Leaflet
# Lekka aplikacja — SQLite bundled, zero zewnętrznych zależności.
# Opcjonalnie: AI (Groq/OpenRouter/Ollama), Google Photos, SMTP.

set -e

APP_NAME="routepix"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}
REPO_URL="https://github.com/jurczykpawel/routepix.git"

echo "--- 🗺️  RoutePix Setup ---"
echo "Wizualizuj trasy podróży ze zdjęć."
echo ""

# Port binding: Cytrus wymaga 0.0.0.0, Cloudflare/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
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
JWT_SECRET=$(openssl rand -base64 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)

# URL aplikacji
APP_URL="http://localhost:$PORT"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    APP_URL="https://$DOMAIN"
fi

# Pobierz ADMIN_EMAIL od deploy.sh lub użyj domyślnego
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"

# Generuj .env
cat <<EOF | sudo tee .env > /dev/null
# App
DATABASE_URL=file:/app/data/routepix.db
BASE_URL=$APP_URL
JWT_SECRET=$JWT_SECRET
ENCRYPTION_KEY=$ENCRYPTION_KEY
ADMIN_EMAIL=$ADMIN_EMAIL

# Email (wymagane do magic link login)
SMTP_HOST=${SMTP_HOST:-}
SMTP_PORT=${SMTP_PORT:-587}
SMTP_USER=${SMTP_USER:-}
SMTP_PASS=${SMTP_PASS:-}
SMTP_FROM=${SMTP_FROM:-noreply@routepix.com}

# Google Photos (opcjonalnie)
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID:-}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET:-}

# AI — rozpoznawanie scen (opcjonalnie, min. 1 provider)
AI_GROQ_API_KEY=${AI_GROQ_API_KEY:-}
AI_GROQ_MODEL=${AI_GROQ_MODEL:-llama-3.2-90b-vision-preview}
AI_OPENROUTER_API_KEY=${AI_OPENROUTER_API_KEY:-}
AI_OPENROUTER_MODEL=${AI_OPENROUTER_MODEL:-meta-llama/llama-3.2-90b-vision-instruct}

# OSRM — dopasowanie trasy do dróg (opcjonalnie)
OSRM_BASE_URL=${OSRM_BASE_URL:-https://router.project-osrm.org}
EOF

sudo chmod 600 .env
echo "✅ Konfiguracja wygenerowana"

# Generuj docker-compose.yaml
cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  app:
    build:
      context: ./repo
      dockerfile: Dockerfile
    restart: always
    ports:
      - "${BIND_ADDR}${PORT}:3000"
    env_file: .env
    volumes:
      - app_data:/app/data
      - app_uploads:/app/uploads
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
    deploy:
      resources:
        limits:
          memory: 512M

volumes:
  app_data:
  app_uploads:
EOF

# Buduj i uruchamiaj
echo "🔨 Buduję obraz Docker (to może potrwać kilka minut)..."
sudo docker compose build --quiet 2>/dev/null || sudo docker compose build
sudo docker builder prune -f >/dev/null 2>&1 || true
sudo docker compose up -d

# Health check
echo "⏳ Czekam na uruchomienie (~20-30s)..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 60 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    for i in $(seq 1 6); do
        sleep 10
        if curl -sf "http://localhost:$PORT/" > /dev/null 2>&1; then
            echo "✅ RoutePix działa (po $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 6 ]; then
            echo "❌ Kontener nie wystartował w 60s!"
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ RoutePix zainstalowany!"
echo "════════════════════════════════════════════════════════════════"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Aplikacja: https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Dostęp przez SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
    echo "   http://localhost:$PORT"
fi
echo ""
echo "🔑 Sekrety zapisane w: $STACK_DIR/.env"
echo "📧 Admin email: $ADMIN_EMAIL"
echo ""
echo "📋 Następne kroki:"
echo "   1. Skonfiguruj SMTP w .env (magic link login wymaga maila)"
echo "   2. Otwórz aplikację → magic link na $ADMIN_EMAIL"
echo "   3. Wgraj zdjęcia geotagowane lub zaimportuj z Google Photos"
echo ""
echo "📋 Opcjonalnie:"
echo "   - AI (Groq/OpenRouter) → rozpoznawanie scen na zdjęciach"
echo "   - Google Photos → import albumów z geolokalizacją"
echo "   - OSRM → trasy dopasowane do dróg"
