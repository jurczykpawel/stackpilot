#!/bin/bash

# Mikrus Toolbox - Umami Analytics
# Simple, privacy-friendly alternative to Google Analytics.
#
# IMAGE_SIZE_MB=500  # ghcr.io/umami-software/umami:postgresql-latest (Next.js ~500MB)
#
# WYMAGANIA: PostgreSQL z rozszerzeniem pgcrypto!
#     Współdzielona baza Mikrusa NIE działa (brak uprawnień do tworzenia rozszerzeń).
#     Użyj: płatny PostgreSQL z https://mikr.us/panel/?a=cloud
#
# Author: Paweł (Lazy Engineer)
#
# Wymagane zmienne środowiskowe (przekazywane przez deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS
#   DB_SCHEMA (opcjonalne - domyślnie public)

set -e

APP_NAME="umami"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}

echo "--- 📊 Umami Analytics Setup ---"
echo "Requires PostgreSQL Database with pgcrypto extension."

# Validate database credentials
if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
    echo "❌ Błąd: Brak danych bazy danych!"
    echo "   Wymagane zmienne: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS"
    exit 1
fi

echo "✅ Dane bazy danych:"
echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"

DB_PORT=${DB_PORT:-5432}
DB_SCHEMA=${DB_SCHEMA:-umami}

if [ "$DB_SCHEMA" != "public" ]; then
    echo "   Schemat: $DB_SCHEMA"
fi

# Check for shared Mikrus DB (doesn't support pgcrypto)
if [[ "$DB_HOST" == psql*.mikr.us ]]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ BŁĄD: Umami NIE działa ze współdzieloną bazą Mikrusa!      ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Umami wymaga rozszerzenia 'pgcrypto', które nie jest          ║"
    echo "║  dostępne w darmowej bazie Mikrusa.                            ║"
    echo "║                                                                ║"
    echo "║  Rozwiązanie: Kup dedykowany PostgreSQL                        ║"
    echo "║  https://mikr.us/panel/?a=cloud                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# Build DATABASE_URL
if [ "$DB_SCHEMA" = "public" ]; then
    DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"
else
    DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME?schema=$DB_SCHEMA"
    echo "ℹ️  Używam schematu: $DB_SCHEMA"
fi

# Generate random hash salt
HASH_SALT=$(openssl rand -hex 32)

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  umami:
    image: ghcr.io/umami-software/umami:postgresql-latest
    restart: always
    ports:
      - "$PORT:3000"
    environment:
      - DATABASE_URL=$DATABASE_URL
      - DATABASE_TYPE=postgresql
      - APP_SECRET=$HASH_SALT
    deploy:
      resources:
        limits:
          memory: 256M
EOF

sudo docker compose up -d

# Health check
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    if ! wait_for_healthy "$APP_NAME" "$PORT" 60; then
        echo "❌ Instalacja nie powiodła się!"
        exit 1
    fi
else
    echo "Sprawdzam czy kontener wystartował..."
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Kontener działa"
    else
        echo "❌ Kontener nie wystartował!"
        sudo docker compose logs --tail 20
        exit 1
    fi
fi

echo ""
echo "✅ Umami zainstalowane pomyślnie"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo "Default user: admin / umami"
echo "👉 CHANGE PASSWORD IMMEDIATELY!"
