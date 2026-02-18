#!/bin/bash

# Mikrus Toolbox - Cap (Open Source Loom Alternative)
# Nagrywaj, edytuj i udostępniaj wideo w sekundy.
# https://github.com/CapSoftware/Cap
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=1500  # cap-web ~1.5GB (z MinIO/MySQL może być więcej)
# UWAGA: Cap wymaga MySQL + S3/MinIO. Z lokalnymi kontenerami potrzebuje:
#        - ~1.5GB+ RAM (cap 512MB + MySQL 512MB + MinIO 256MB)
#        - ~4GB dysku na obrazy
#        Zalecany plan: Mikrus 3.0+ (2GB RAM)

set -e

APP_NAME="cap"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}

echo "--- 🎬 Cap Setup (Loom Alternative) ---"
echo "Cap pozwala nagrywać ekran i udostępniać wideo."
echo ""

# Wymagane: DOMAIN
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "-" ]; then
    echo "❌ Brak wymaganej zmiennej: DOMAIN"
    echo ""
    echo "   Użycie (zewnętrzna baza + zewnętrzny S3):"
    echo "   DB_HOST=mysql.mikr.us DB_PORT=3306 DB_NAME=cap \\"
    echo "   DB_USER=myuser DB_PASS=secret \\"
    echo "   S3_ENDPOINT=https://xxx.r2.cloudflarestorage.com \\"
    echo "   S3_PUBLIC_URL=https://cdn.example.com \\"
    echo "   S3_REGION=auto S3_BUCKET=cap-videos \\"
    echo "   S3_ACCESS_KEY=xxx S3_SECRET_KEY=yyy \\"
    echo "   DOMAIN=cap.example.com ./install.sh"
    echo ""
    echo "   Użycie (lokalna baza + lokalny MinIO):"
    echo "   MYSQL_ROOT_PASS=secret USE_LOCAL_MINIO=true \\"
    echo "   DOMAIN=cap.example.com ./install.sh"
    exit 1
fi

echo "✅ Domena: $DOMAIN"

# 1. Konfiguracja bazy MySQL
echo "=== Konfiguracja MySQL ==="

if [ -n "$DB_HOST" ] && [ -n "$DB_USER" ]; then
    # Zewnętrzna baza MySQL
    echo "✅ Używam zewnętrznej bazy MySQL:"
    echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"
    DB_PORT=${DB_PORT:-3306}
    DATABASE_URL="mysql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    USE_LOCAL_MYSQL="false"
elif [ -n "$MYSQL_ROOT_PASS" ]; then
    # Lokalna baza MySQL
    echo "✅ Używam lokalnej bazy MySQL (kontener)"
    MYSQL_DB="cap"
    DATABASE_URL="mysql://root:${MYSQL_ROOT_PASS}@cap-mysql:3306/${MYSQL_DB}"
    USE_LOCAL_MYSQL="true"
else
    echo "❌ Brak konfiguracji MySQL!"
    echo "   Opcja 1 (zewnętrzna): DB_HOST, DB_USER, DB_PASS, DB_NAME"
    echo "   Opcja 2 (lokalna): MYSQL_ROOT_PASS"
    exit 1
fi

# 2. Konfiguracja S3 Storage
echo ""
echo "=== Konfiguracja Storage (S3) ==="

if [ -n "$S3_ENDPOINT" ] && [ -n "$S3_ACCESS_KEY" ]; then
    # Zewnętrzny S3
    echo "✅ Używam zewnętrznego S3:"
    echo "   Endpoint: $S3_ENDPOINT | Bucket: $S3_BUCKET"
    USE_LOCAL_MINIO="false"
elif [ "$USE_LOCAL_MINIO" == "true" ]; then
    # Lokalny MinIO
    echo "✅ Używam lokalnego MinIO (kontener)"
    S3_ACCESS_KEY="capS3root"
    S3_SECRET_KEY="capS3root"
    S3_BUCKET="cap-videos"
    S3_REGION="us-east-1"
    S3_ENDPOINT="http://cap-minio:9000"
    S3_PUBLIC_URL="https://${DOMAIN}:3902"
    echo "⚠️  MinIO będzie dostępny na porcie 3902"
else
    echo "❌ Brak konfiguracji S3!"
    echo "   Opcja 1 (zewnętrzny): S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY, S3_BUCKET, S3_REGION, S3_PUBLIC_URL"
    echo "   Opcja 2 (lokalny): USE_LOCAL_MINIO=true"
    exit 1
fi

# Generowanie secretów
echo ""
echo "Generuję klucze bezpieczeństwa..."
NEXTAUTH_SECRET=$(openssl rand -base64 32)
DATABASE_ENCRYPTION_KEY=$(openssl rand -base64 32)

# 4. Przygotowanie katalogu
sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# 5. Generowanie docker-compose.yaml
echo "--- Tworzę konfigurację Docker ---"

cat <<EOF | sudo tee docker-compose.yaml

services:
  cap-web:
    image: ghcr.io/capsoftware/cap-web:latest
    restart: unless-stopped
    ports:
      - "${PORT}:3000"
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - WEB_URL=https://${DOMAIN}
      - NEXTAUTH_URL=https://${DOMAIN}
      - NEXTAUTH_SECRET=${NEXTAUTH_SECRET}
      - DATABASE_ENCRYPTION_KEY=${DATABASE_ENCRYPTION_KEY}
      - CAP_AWS_ACCESS_KEY=${S3_ACCESS_KEY}
      - CAP_AWS_SECRET_KEY=${S3_SECRET_KEY}
      - CAP_AWS_BUCKET=${S3_BUCKET}
      - CAP_AWS_REGION=${S3_REGION}
      - S3_PUBLIC_ENDPOINT=${S3_PUBLIC_URL}
      - S3_INTERNAL_ENDPOINT=${S3_ENDPOINT}
EOF

# Dodaj lokalne serwisy jeśli potrzebne
if [ "$USE_LOCAL_MYSQL" == "true" ]; then
cat <<EOF | sudo tee -a docker-compose.yaml
    depends_on:
      - cap-mysql

  cap-mysql:
    image: mysql:8.0
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
      - MYSQL_DATABASE=${MYSQL_DB}
    volumes:
      - ./mysql-data:/var/lib/mysql
    deploy:
      resources:
        limits:
          memory: 512M
EOF
fi

if [ "$USE_LOCAL_MINIO" == "true" ]; then
cat <<EOF | sudo tee -a docker-compose.yaml

  cap-minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    restart: unless-stopped
    ports:
      - "127.0.0.1:3902:9000"
      - "127.0.0.1:3903:9001"
    environment:
      - MINIO_ROOT_USER=${S3_ACCESS_KEY}
      - MINIO_ROOT_PASSWORD=${S3_SECRET_KEY}
    volumes:
      - ./minio-data:/data
    deploy:
      resources:
        limits:
          memory: 256M
EOF
fi

# Bind mounts są używane zamiast named volumes - dane w /opt/stacks/cap/
# Dzięki temu backup automatycznie obejmuje mysql-data/ i minio-data/

# Memory limit dla cap-web
sudo sed -i '/cap-web:/,/environment:/{ /image:/a\    deploy:\n      resources:\n        limits:\n          memory: 512M' docker-compose.yaml 2>/dev/null || true

echo ""
echo "--- Uruchamiam Cap ---"
sudo docker compose up -d

# Health check
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 90 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    sleep 10
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Cap działa"
    else
        echo "❌ Kontener nie wystartował!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Create MinIO bucket if using local MinIO
if [ "$USE_LOCAL_MINIO" == "true" ]; then
    echo ""
    echo "--- Tworzę bucket MinIO ---"
    sleep 3  # Poczekaj na start MinIO

    # MinIO automatycznie tworzy bucket przy pierwszym użyciu przez Cap
    # Alternatywnie można użyć mc client zainstalowanego na hoście:
    # mc alias set cap-minio http://localhost:3902 ${S3_ACCESS_KEY} ${S3_SECRET_KEY}
    # mc mb cap-minio/${S3_BUCKET}
    echo "ℹ️  Bucket zostanie utworzony automatycznie przy pierwszym użyciu"
fi

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo ""
    echo "--- Konfiguruję HTTPS via Caddy ---"
    if command -v mikrus-expose &> /dev/null; then
        sudo mikrus-expose "$DOMAIN" "$PORT"
    else
        echo "⚠️  'mikrus-expose' nie znaleziono. Zainstaluj Caddy: system/caddy-install.sh"
        echo "   Lub skonfiguruj reverse proxy ręcznie na port $PORT"
    fi
fi

if [ "$USE_LOCAL_MINIO" == "true" ]; then
    echo ""
    echo "⚠️  MinIO wymaga osobnej konfiguracji proxy dla portu 3902"
    echo "   Lub skonfiguruj external S3 (Cloudflare R2, AWS S3, etc.)"
fi

echo ""
echo "============================================"
echo "✅ Cap zainstalowany!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Otwórz https://$DOMAIN aby rozpocząć"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Dostęp przez SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo ""
echo "📝 Zapisz te dane w bezpiecznym miejscu:"
echo "   NEXTAUTH_SECRET: $NEXTAUTH_SECRET"
echo "   DATABASE_ENCRYPTION_KEY: $DATABASE_ENCRYPTION_KEY"
echo "============================================"
