#!/bin/bash

# StackPilot - n8n (External Database Optimized)
# Installs n8n optimized for low-RAM environment, connecting to external PostgreSQL.
# Author: Paweł (Lazy Engineer)
#
# REQUIREMENTS: PostgreSQL with pgcrypto extension!
#     Shared database does NOT work (no permissions to create extensions).
#     Use: a dedicated PostgreSQL instance
#
# IMAGE_SIZE_MB=800  # n8nio/n8n:latest
#
# Required environment variables (passed by deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS
#   DOMAIN (optional - for webhook configuration)

set -e

APP_NAME="n8n"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-5678}

echo "--- 🧠 n8n Setup (Smart Mode) ---"
echo "This setup uses External PostgreSQL (saves RAM and CPU on your VPS)."
echo ""

# 1. Validate database credentials
if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
    echo "❌ Error: Missing database credentials!"
    echo "   Required variables: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS"
    echo ""
    echo "   Use deploy.sh with --db-source=... options or run interactively."
    exit 1
fi

echo "✅ Database credentials:"
echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"

DB_PORT=${DB_PORT:-5432}
DB_SCHEMA=${DB_SCHEMA:-n8n}

# Check for shared DB (doesn't support pgcrypto)
if [[ "$DB_HOST" == psql*.mikr.us ]]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ ERROR: n8n does NOT work with a shared database!         ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  n8n requires the 'pgcrypto' extension (gen_random_uuid),    ║"
    echo "║  which is not available on the free shared database.         ║"
    echo "║                                                              ║"
    echo "║  Solution: Use a dedicated PostgreSQL instance               ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

if [ "$DB_SCHEMA" != "public" ]; then
    echo "   Schema: $DB_SCHEMA"
fi

# 2. Domain and webhook URL
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
    WEBHOOK_URL="https://$DOMAIN/"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Cytrus) — WEBHOOK_URL will be updated"
    WEBHOOK_URL=""
else
    echo "⚠️  No domain - webhooks will require manual configuration"
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
# - Memory limits (critical for small VPS)
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
    echo "--- Configuring HTTPS via Caddy ---"
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    else
        echo "⚠️  'sp-expose' not found. Install Caddy first or configure reverse proxy manually."
    fi
fi

echo ""
echo "✅ n8n Installed & Started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN to finish setup."
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
    echo "   Then open: http://localhost:$PORT"
fi
