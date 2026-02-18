#!/bin/bash

# Mikrus Toolbox - Listmonk
# High-performance self-hosted newsletter and mailing list manager.
# Alternative to Mailchimp / MailerLite.
# Written in Go - very lightweight.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=150  # listmonk/listmonk:latest (Go binary, ~150MB)
#
# WYMAGANIA: PostgreSQL z rozszerzeniem pgcrypto!
#     Współdzielona baza Mikrusa NIE działa (brak uprawnień do tworzenia rozszerzeń).
#     Użyj: płatny PostgreSQL z https://mikr.us/panel/?a=cloud
#
# Wymagane zmienne środowiskowe (przekazywane przez deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS
#   DOMAIN (opcjonalne)

set -e

APP_NAME="listmonk"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-9000}

echo "--- 📧 Listmonk Setup ---"
echo "Requires PostgreSQL Database."

# Validate database credentials
if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
    echo "❌ Błąd: Brak danych bazy danych!"
    echo "   Wymagane zmienne: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS"
    exit 1
fi

echo "✅ Dane bazy danych:"
echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"

DB_PORT=${DB_PORT:-5432}

# Check for shared Mikrus DB (doesn't support pgcrypto)
if [[ "$DB_HOST" == psql*.mikr.us ]]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ BŁĄD: Listmonk NIE działa ze współdzieloną bazą Mikrusa!   ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Listmonk (od v6.0.0) wymaga rozszerzenia 'pgcrypto',          ║"
    echo "║  które nie jest dostępne w darmowej bazie Mikrusa.             ║"
    echo "║                                                                ║"
    echo "║  Rozwiązanie: Kup dedykowany PostgreSQL                        ║"
    echo "║  https://mikr.us/panel/?a=cloud                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domena: $DOMAIN"
    ROOT_URL="https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domena: automatyczna (Cytrus) — ROOT_URL zostanie zaktualizowany"
    ROOT_URL="http://localhost:$PORT"
else
    echo "⚠️  Brak domeny - używam localhost"
    ROOT_URL="http://localhost:$PORT"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  listmonk:
    image: listmonk/listmonk:latest
    restart: always
    ports:
      - "$PORT:9000"
    environment:
      - TZ=Europe/Warsaw
      - LISTMONK_db__host=$DB_HOST
      - LISTMONK_db__port=$DB_PORT
      - LISTMONK_db__user=$DB_USER
      - LISTMONK_db__password=$DB_PASS
      - LISTMONK_db__database=$DB_NAME
      - LISTMONK_app__address=0.0.0.0:9000
      - LISTMONK_app__root_url=$ROOT_URL
    volumes:
      - ./data:/listmonk/uploads
    deploy:
      resources:
        limits:
          memory: 256M

EOF

# 1. Run Install (Migrate DB)
echo "Running database migrations..."
sudo docker compose run --rm listmonk ./listmonk --install --yes || echo "Migrations already done or failed."

# 2. Start Service
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
echo "✅ Listmonk started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo "Default user: admin / listmonk"
echo "👉 CONFIGURE YOUR SMTP SERVER IN SETTINGS TO SEND EMAILS."
