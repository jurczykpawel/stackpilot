#!/bin/bash

# Mikrus Toolbox - ConvertX
# Self-hosted file converter. Images, documents, audio, video - 1000+ formats.
# https://github.com/C4illin/ConvertX
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=5300  # ghcr.io/c4illin/convertx:latest (1.4GB compressed → 5.3GB on disk)

set -e

APP_NAME="convertx"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}

echo "--- 🔄 ConvertX Setup ---"
echo "Uniwersalny konwerter plików w przeglądarce."
echo ""

# Port binding: Cytrus wymaga 0.0.0.0, Cloudflare/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

# JWT secret - bez tego sesje giną po restarcie kontenera
JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domena: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domena: automatyczna (Cytrus)"
else
    echo "⚠️  Brak domeny - użyj --domain=... lub dostęp przez SSH tunnel"
fi

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  convertx:
    image: ghcr.io/c4illin/convertx:latest
    restart: always
    ports:
      - "${BIND_ADDR}$PORT:3000"
    environment:
      - JWT_SECRET=$JWT_SECRET
      - ACCOUNT_REGISTRATION=true
      - AUTO_DELETE_EVERY_N_HOURS=24
      - TZ=Europe/Warsaw
    volumes:
      - ./data:/app/data
    healthcheck:
      test: ["CMD", "curl", "-f", "-s", "http://localhost:3000/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: 512M
EOF

sudo docker compose up -d

# Health check
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 90 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ ConvertX działa na porcie $PORT"
    else
        echo "❌ Kontener nie wystartował!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ ConvertX zainstalowany!"
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
echo "   2. Po utworzeniu konta wyłącz rejestrację:"
echo "      ssh <server> 'cd $STACK_DIR && sed -i \"s/ACCOUNT_REGISTRATION=true/ACCOUNT_REGISTRATION=false/\" docker-compose.yaml && docker compose up -d'"
echo ""
echo "💡 Pliki starsze niż 24h są automatycznie usuwane."
echo "   Zmień AUTO_DELETE_EVERY_N_HOURS w docker-compose.yaml (0 = wyłącz)."
