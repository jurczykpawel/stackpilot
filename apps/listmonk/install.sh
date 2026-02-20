#!/bin/bash

# StackPilot - Listmonk
# High-performance self-hosted newsletter and mailing list manager.
# Alternative to Mailchimp / MailerLite.
# Written in Go - very lightweight.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=150  # listmonk/listmonk:latest (Go binary, ~150MB)
#
# REQUIREMENTS: PostgreSQL with pgcrypto extension!
#     Shared database does NOT work (no permissions to create extensions).
#     Use: a dedicated PostgreSQL instance
#
# Required environment variables (passed by deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS
#   DOMAIN (optional)

set -e

APP_NAME="listmonk"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-9000}

echo "--- 📧 Listmonk Setup ---"
echo "Requires PostgreSQL Database."

# Validate database credentials
if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
    echo "❌ Error: Missing database credentials!"
    echo "   Required variables: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS"
    exit 1
fi

echo "✅ Database credentials:"
echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"

DB_PORT=${DB_PORT:-5432}

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
    ROOT_URL="https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Caddy) — ROOT_URL will be updated"
    ROOT_URL="http://localhost:$PORT"
else
    echo "⚠️  No domain - using localhost"
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

# Append bundled database service if using bundled DB
if [ -n "$BUNDLED_DB_TYPE" ]; then
    # Add depends_on to main service
    sudo sed -i '/restart: always/a\    depends_on:\n      - db' docker-compose.yaml

    if [ "$BUNDLED_DB_TYPE" = "postgres" ]; then
        cat <<DBEOF | sudo tee -a docker-compose.yaml > /dev/null
  db:
    image: postgres:16-alpine
    restart: always
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - db-data:/var/lib/postgresql/data
    deploy:
      resources:
        limits:
          memory: 256M

volumes:
  db-data:
DBEOF
    fi
fi

# 1. Run Install (Migrate DB)
echo "Running database migrations..."
sudo docker compose run --rm listmonk ./listmonk --install --yes || echo "Migrations already done or failed."

# 2. Start Service
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
echo "✅ Listmonk started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo "Default user: admin / listmonk"
echo "👉 CONFIGURE YOUR SMTP SERVER IN SETTINGS TO SEND EMAILS."
