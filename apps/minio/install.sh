#!/bin/bash

# Mikrus Toolbox - MinIO (S3-Compatible Object Storage)
# Self-hosted S3-compatible storage for files, backups, and media.
# https://min.io/
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=300  # minio/minio:latest ~300MB
#
# MinIO może być używany jako storage dla:
# - Cap (nagrania wideo)
# - Typebot (pliki uploadowane przez użytkowników)
# - Dowolna aplikacja wymagająca S3

set -e

APP_NAME="minio"
STACK_DIR="/opt/stacks/$APP_NAME"
API_PORT=${PORT:-9000}
CONSOLE_PORT=${CONSOLE_PORT:-9001}

echo "--- 📦 MinIO Setup (S3-Compatible Storage) ---"
echo "MinIO to self-hosted storage kompatybilny z Amazon S3."
echo ""

# Generuj losowe credentials jeśli nie podano
if [ -z "$MINIO_ROOT_USER" ]; then
    MINIO_ROOT_USER="admin"
fi

if [ -z "$MINIO_ROOT_PASSWORD" ]; then
    MINIO_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    echo "🔐 Wygenerowano hasło root: $MINIO_ROOT_PASSWORD"
fi

# Opcjonalnie: domyślny bucket
DEFAULT_BUCKET=${DEFAULT_BUCKET:-}

echo "✅ Konfiguracja:"
echo "   API Port: $API_PORT (S3 endpoint)"
echo "   Console Port: $CONSOLE_PORT (Web UI)"
echo "   Root User: $MINIO_ROOT_USER"
if [ -n "$DEFAULT_BUCKET" ]; then
    echo "   Default Bucket: $DEFAULT_BUCKET"
fi
echo ""

# Przygotowanie katalogu
sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Tworzenie docker-compose.yaml
echo "--- Tworzę konfigurację Docker ---"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  minio:
    image: minio/minio:latest
    container_name: minio
    command: server /data --console-address ":9001"
    restart: unless-stopped
    ports:
      - "${API_PORT}:9000"
      - "${CONSOLE_PORT}:9001"
    environment:
      - MINIO_ROOT_USER=${MINIO_ROOT_USER}
      - MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
    volumes:
      - ./data:/data
    deploy:
      resources:
        limits:
          memory: 256M
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

EOF

echo "--- Uruchamiam MinIO ---"
sudo docker compose up -d

# Health check
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$API_PORT" 60 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ MinIO działa"
    else
        echo "❌ Kontener nie wystartował!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Tworzenie domyślnego bucketu jeśli podano
if [ -n "$DEFAULT_BUCKET" ]; then
    echo ""
    echo "--- Tworzę bucket: $DEFAULT_BUCKET ---"
    sleep 3  # Poczekaj na pełny start MinIO

    # Użyj mc wewnątrz kontenera (dostępny od MinIO RELEASE.2023-03-20)
    # Alternatywnie: curl do API
    if sudo docker exec minio mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" 2>/dev/null; then
        if sudo docker exec minio mc mb local/"$DEFAULT_BUCKET" 2>/dev/null; then
            echo "✅ Bucket '$DEFAULT_BUCKET' utworzony"
        else
            echo "⚠️  Bucket może już istnieć lub wystąpił błąd"
        fi
    else
        echo "⚠️  mc client niedostępny - bucket zostanie utworzony przy pierwszym użyciu"
    fi
fi

# Zapisz credentials do pliku
echo ""
echo "💾 Zapisuję credentials do $STACK_DIR/.env..."
cat <<EOF | sudo tee "$STACK_DIR/.env" > /dev/null
# MinIO Credentials
# Wygenerowane przez install.sh - NIE USUWAJ!
MINIO_ROOT_USER=$MINIO_ROOT_USER
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
MINIO_ENDPOINT=http://localhost:$API_PORT
EOF
sudo chmod 600 "$STACK_DIR/.env"

# Konfiguracja HTTPS
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo ""
    echo "--- Konfiguruję HTTPS via Caddy ---"
    if command -v mikrus-expose &> /dev/null; then
        # Expose Console (Web UI)
        sudo mikrus-expose "$DOMAIN" "$CONSOLE_PORT"
        echo "✅ Console dostępne na https://$DOMAIN"

        # Info o API endpoint
        echo ""
        echo "⚠️  S3 API (port $API_PORT) wymaga osobnej konfiguracji:"
        echo "   Dla zewnętrznego dostępu do S3 API użyj subdomeny, np.:"
        echo "   s3.$DOMAIN -> localhost:$API_PORT"
    else
        echo "⚠️  'mikrus-expose' nie znaleziono. Zainstaluj Caddy: system/caddy-install.sh"
    fi
fi

echo ""
echo "============================================"
echo "✅ MinIO zainstalowany!"
echo ""
echo "📋 Dostęp:"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "   Console (Web UI): https://$DOMAIN"
    echo "   S3 API: http://localhost:$API_PORT (lokalnie)"
elif [ "$DOMAIN" = "-" ]; then
    echo "   Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "   Console (Web UI): http://localhost:$CONSOLE_PORT"
    echo "   S3 API: http://localhost:$API_PORT"
fi
echo ""
echo "🔐 Credentials:"
echo "   User: $MINIO_ROOT_USER"
echo "   Password: $MINIO_ROOT_PASSWORD"
echo ""
echo "📝 Użycie z innymi aplikacjami:"
echo "   S3_ENDPOINT=http://minio:9000"
echo "   S3_ACCESS_KEY=$MINIO_ROOT_USER"
echo "   S3_SECRET_KEY=$MINIO_ROOT_PASSWORD"
echo "   S3_BUCKET=<nazwa-bucketu>"
echo ""
echo "💡 Tworzenie bucketu przez CLI:"
echo "   docker exec minio mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD"
echo "   docker exec minio mc mb local/nazwa-bucketu"
echo "============================================"
