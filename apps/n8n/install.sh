#!/bin/bash

# Mikrus Toolbox - n8n (External Database Optimized)
# Installs n8n optimized for low-RAM environment, connecting to external PostgreSQL.
# Author: Paweł (Lazy Engineer)
#
# WYMAGANIA: PostgreSQL z rozszerzeniem pgcrypto!
#     Współdzielona baza Mikrusa NIE działa (brak uprawnień do tworzenia rozszerzeń).
#     Użyj: płatny PostgreSQL z https://mikr.us/panel/?a=cloud
#
# IMAGE_SIZE_MB=800  # n8nio/n8n:latest
#
# Wymagane zmienne środowiskowe (przekazywane przez deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS
#   DOMAIN (opcjonalne - dla konfiguracji webhooków)

set -e

APP_NAME="n8n"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-5678}

echo "--- 🧠 n8n Setup (Smart Mode) ---"
echo "This setup uses External PostgreSQL (saves RAM and CPU on your VPS)."
echo ""

# 1. Validate database credentials
if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
    echo "❌ Błąd: Brak danych bazy danych!"
    echo "   Wymagane zmienne: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS"
    echo ""
    echo "   Użyj deploy.sh z opcjami --db-source=... lub uruchom interaktywnie."
    exit 1
fi

echo "✅ Dane bazy danych:"
echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"

DB_PORT=${DB_PORT:-5432}
DB_SCHEMA=${DB_SCHEMA:-n8n}

# Check for shared Mikrus DB (doesn't support pgcrypto)
if [[ "$DB_HOST" == psql*.mikr.us ]]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ BŁĄD: n8n NIE działa ze współdzieloną bazą Mikrusa!        ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  n8n wymaga rozszerzenia 'pgcrypto' (gen_random_uuid),         ║"
    echo "║  które nie jest dostępne w darmowej bazie Mikrusa.             ║"
    echo "║                                                                ║"
    echo "║  Rozwiązanie: Kup dedykowany PostgreSQL                        ║"
    echo "║  https://mikr.us/panel/?a=cloud                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

if [ "$DB_SCHEMA" != "public" ]; then
    echo "   Schemat: $DB_SCHEMA"
fi

# 2. Domain and webhook URL
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domena: $DOMAIN"
    WEBHOOK_URL="https://$DOMAIN/"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domena: automatyczna (Cytrus) — WEBHOOK_URL zostanie zaktualizowany"
    WEBHOOK_URL=""
else
    echo "⚠️  Brak domeny - webhooks będą wymagały ręcznej konfiguracji"
    WEBHOOK_URL=""
fi

# 3. Prepare Directory
sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Create data directory with correct permissions (n8n runs as UID 1000)
sudo mkdir -p "$STACK_DIR/data"
sudo chown -R 1000:1000 "$STACK_DIR/data"

# 4. Create docker-compose.yaml
# Features:
# - External DB connection
# - Memory limits (critical for Mikrus)
# - Timezone set to Europe/Warsaw
# - Execution logs pruning (keep DB small)

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  n8n:
    image: docker.n8n.io/n8nio/n8n
    restart: always
    ports:
      - "$PORT:5678"
    environment:
      - N8N_HOST=${DOMAIN:-localhost}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=${WEBHOOK_URL:-}
      - GENERIC_TIMEZONE=Europe/Warsaw
      - TZ=Europe/Warsaw

      # Database Configuration
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=$DB_HOST
      - DB_POSTGRESDB_PORT=$DB_PORT
      - DB_POSTGRESDB_DATABASE=$DB_NAME
      - DB_POSTGRESDB_SCHEMA=$DB_SCHEMA
      - DB_POSTGRESDB_USER=$DB_USER
      - DB_POSTGRESDB_PASSWORD=$DB_PASS

      # Security
      - N8N_BASIC_AUTH_ACTIVE=true
      # (User will set up user/pass on first launch via UI)

      # Pruning (Keep database slim)
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168 # 7 Days
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000

      # Memory Optimization
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=true
    volumes:
      - ./data:/home/node/.n8n
    deploy:
      resources:
        limits:
          memory: 600M  # Prevent n8n from killing the server

EOF

echo "--- Starting n8n ---"
sudo docker compose up -d

# Health check - wait for container to be running
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

# Caddy/HTTPS - only for real domains (not Cytrus placeholder)
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ] && [[ "$DOMAIN" != *"pending"* ]] && [[ "$DOMAIN" != *"cytrus"* ]]; then
    echo "--- Configuring HTTPS via Caddy ---"
    if command -v mikrus-expose &> /dev/null; then
        sudo mikrus-expose "$DOMAIN" "$PORT"
    else
        echo "⚠️  'mikrus-expose' not found. Install Caddy first or configure reverse proxy manually."
    fi
fi

echo ""
echo "✅ n8n Installed & Started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN to finish setup."
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
    echo "   Then open: http://localhost:$PORT"
fi
