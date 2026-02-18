#!/bin/bash

# Mikrus Toolbox - NocoDB
# Open Source Airtable alternative.
# Connects to your own database and turns it into a spreadsheet.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=400  # nocodb/nocodb:latest (Node.js app ~400MB)
#
# Wymagane zmienne środowiskowe (przekazywane przez deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS (opcjonalne - bez nich używa SQLite)
#   DOMAIN (opcjonalne)

set -e

APP_NAME="nocodb"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8080}

echo "--- 📅 NocoDB Setup ---"

# Database - optional (defaults to internal SQLite)
DB_URL=""
if [ -n "$DB_HOST" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASS" ] && [ -n "$DB_NAME" ]; then
    DB_PORT=${DB_PORT:-5432}
    DB_SCHEMA=${DB_SCHEMA:-nocodb}
    # NocoDB używa własnego formatu URL (pg://...)
    # Schema jest obsługiwana przez parametr 's' (jeśli aplikacja to wspiera)
    if [ "$DB_SCHEMA" = "public" ]; then
        DB_URL="pg://$DB_HOST:$DB_PORT?u=$DB_USER&p=$DB_PASS&d=$DB_NAME"
    else
        DB_URL="pg://$DB_HOST:$DB_PORT?u=$DB_USER&p=$DB_PASS&d=$DB_NAME&search_path=$DB_SCHEMA"
    fi
    echo "✅ Dane bazy danych:"
    echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"
    if [ "$DB_SCHEMA" != "public" ]; then
        echo "   Schemat: $DB_SCHEMA"
    fi
else
    echo "⚠️  Brak danych bazy - używam wbudowanego SQLite"
    echo "   (Wyższe zużycie RAM, dane lokalne w kontenerze)"
fi

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domena: $DOMAIN"
    PUBLIC_URL="https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domena: automatyczna (Cytrus) — PUBLIC_URL zostanie zaktualizowany"
    PUBLIC_URL="http://localhost:$PORT"
else
    echo "⚠️  Brak domeny - używam localhost"
    PUBLIC_URL="http://localhost:$PORT"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  nocodb:
    image: nocodb/nocodb:latest
    restart: always
    ports:
      - "$PORT:8080"
    environment:
      - NC_DB=$DB_URL
      - NC_PUBLIC_URL=$PUBLIC_URL
    volumes:
      - ./data:/usr/app/data
    deploy:
      resources:
        limits:
          memory: 400M

EOF

sudo docker compose up -d

# Health check
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 60 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Kontener działa"
    else
        echo "❌ Kontener nie wystartował!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Caddy/HTTPS - only for real domains
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ] && [[ "$DOMAIN" != *"pending"* ]] && [[ "$DOMAIN" != *"cytrus"* ]]; then
    if command -v mikrus-expose &> /dev/null; then
        sudo mikrus-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ NocoDB started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
