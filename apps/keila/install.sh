#!/bin/bash

# StackPilot - Keila
# Open-source email marketing platform — self-hosted alternative to Mailchimp/Brevo.
# Manage newsletters, campaigns, and subscriber lists with a clean UI.
# https://www.keila.io/
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=200  # pentacent/keila:latest (Elixir/Phoenix, ~200MB)
#
# REQUIREMENTS: PostgreSQL
#     Keila requires a PostgreSQL database.
#     Can use bundled postgres:16-alpine or an external PostgreSQL instance.
#
# Required environment variables (passed by deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS
#   DOMAIN (optional)

set -e

APP_NAME="keila"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-4500}

if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

echo "--- 📧 Keila Email Marketing Setup ---"
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

DB_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"

# Domain configuration
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
    URL_HOST="$DOMAIN"
    URL_SCHEMA="https"
    URL_PORT_ENV=""
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Caddy) — URL_HOST will be updated"
    URL_HOST="localhost"
    URL_SCHEMA="http"
    URL_PORT_ENV="      - URL_PORT=$PORT"
else
    echo "⚠️  No domain - using localhost (access via SSH tunnel)"
    URL_HOST="localhost"
    URL_SCHEMA="http"
    URL_PORT_ENV="      - URL_PORT=$PORT"
fi

# Generate secret key base
SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  keila:
    image: pentacent/keila:latest
    restart: always
    ports:
      - "${BIND_ADDR}$PORT:4000"
    environment:
      - DB_URL=$DB_URL
      - SECRET_KEY_BASE=$SECRET_KEY_BASE
      - URL_HOST=$URL_HOST
      - URL_SCHEMA=$URL_SCHEMA
$URL_PORT_ENV
      - DISABLE_REGISTRATION=true
      # SMTP (required — configure after installation in Settings → Senders)
      - MAILER_SMTP_HOST=smtp.example.com
      - MAILER_SMTP_FROM_EMAIL=noreply@example.com
      - MAILER_SMTP_USER=user@example.com
      - MAILER_SMTP_PASSWORD=changeme
      - MAILER_SMTP_PORT=587
    volumes:
      - ./uploads:/app/uploads
    deploy:
      resources:
        limits:
          memory: 512M
EOF

# Append bundled database service if using bundled DB
if [ -n "$BUNDLED_DB_TYPE" ]; then
    # Add depends_on with health condition to avoid race on DB init
    sudo sed -i '/restart: always/a\    depends_on:\n      db:\n        condition: service_healthy' docker-compose.yaml

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
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 5s
      retries: 10
    deploy:
      resources:
        limits:
          memory: 256M

volumes:
  db-data:
DBEOF
    fi
fi

echo ""
echo "🚀 Starting Keila..."
sudo docker compose up -d

# Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 90 || { echo "❌ Installation failed!"; exit 1; }
else
    sleep 15
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Keila is running on port $PORT"
    else
        echo "❌ Container failed to start!"; sudo docker compose logs --tail 30; exit 1
    fi
fi

# Caddy/HTTPS - configure reverse proxy if domain is set
if [ -n "$DOMAIN" ]; then
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ Keila started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT $SSH_ALIAS"
    echo "   Then open: http://localhost:$PORT"
fi
echo ""
echo "👤 Default login: root@localhost (password shown in logs on first boot)"
echo "   ssh $SSH_ALIAS 'docker compose -C /opt/stacks/keila logs keila | grep password'"
echo "👉 UPDATE SMTP SETTINGS IN Settings → Senders before sending emails."
echo "📚 Docs: https://www.keila.io/docs"
