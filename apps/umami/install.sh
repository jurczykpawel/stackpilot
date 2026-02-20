#!/bin/bash

# StackPilot - Umami Analytics
# Simple, privacy-friendly alternative to Google Analytics.
#
# IMAGE_SIZE_MB=500  # ghcr.io/umami-software/umami:postgresql-latest (Next.js ~500MB)
#
# REQUIREMENTS: PostgreSQL with pgcrypto extension!
#     Shared database does NOT work (no permissions to create extensions).
#     Use: a dedicated PostgreSQL instance
#
# Author: Paweł (Lazy Engineer)
#
# Required environment variables (passed by deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS
#   DB_SCHEMA (optional - default public)

set -e

APP_NAME="umami"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}

echo "--- 📊 Umami Analytics Setup ---"
echo "Requires PostgreSQL Database with pgcrypto extension."

# Validate database credentials
if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
    echo "❌ Error: Missing database credentials!"
    echo "   Required variables: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS"
    exit 1
fi

echo "✅ Database credentials:"
echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"

DB_PORT=${DB_PORT:-5432}
DB_SCHEMA=${DB_SCHEMA:-umami}

if [ "$DB_SCHEMA" != "public" ]; then
    echo "   Schema: $DB_SCHEMA"
fi

# Build DATABASE_URL
if [ "$DB_SCHEMA" = "public" ]; then
    DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"
else
    DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME?schema=$DB_SCHEMA"
    echo "ℹ️  Using schema: $DB_SCHEMA"
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

sudo docker compose up -d

# Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    if ! wait_for_healthy "$APP_NAME" "$PORT" 60; then
        echo "❌ Installation failed!"
        exit 1
    fi
else
    echo "Checking if container started..."
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Container is running"
    else
        echo "❌ Container failed to start!"
        sudo docker compose logs --tail 20
        exit 1
    fi
fi

echo ""
echo "✅ Umami installed successfully"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo "Default user: admin / umami"
echo "👉 CHANGE PASSWORD IMMEDIATELY!"
