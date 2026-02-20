#!/bin/bash

# StackPilot - NocoDB
# Open Source Airtable alternative.
# Connects to your own database and turns it into a spreadsheet.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=400  # nocodb/nocodb:latest (Node.js app ~400MB)
#
# Required environment variables (passed by deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS (optional - without them uses SQLite)
#   DOMAIN (optional)

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
    # NocoDB uses its own URL format (pg://...)
    # Schema is handled by the 's' parameter (if the app supports it)
    if [ "$DB_SCHEMA" = "public" ]; then
        DB_URL="pg://$DB_HOST:$DB_PORT?u=$DB_USER&p=$DB_PASS&d=$DB_NAME"
    else
        DB_URL="pg://$DB_HOST:$DB_PORT?u=$DB_USER&p=$DB_PASS&d=$DB_NAME&search_path=$DB_SCHEMA"
    fi
    echo "✅ Database credentials:"
    echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"
    if [ "$DB_SCHEMA" != "public" ]; then
        echo "   Schema: $DB_SCHEMA"
    fi
else
    echo "⚠️  No database credentials - using built-in SQLite"
    echo "   (Higher RAM usage, data stored locally in container)"
fi

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
    PUBLIC_URL="https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Caddy) — PUBLIC_URL will be updated"
    PUBLIC_URL="http://localhost:$PORT"
else
    echo "⚠️  No domain - using localhost"
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
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 60 || { echo "❌ Installation failed!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Container is running"
    else
        echo "❌ Container failed to start!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Caddy/HTTPS - configure reverse proxy if domain is set
if [ -n "$DOMAIN" ]; then
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ NocoDB started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
