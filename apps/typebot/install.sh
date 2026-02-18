#!/bin/bash

# StackPilot - Typebot
# Conversational Form Builder (Open Source Typeform Alternative).
# Requires External PostgreSQL.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=3000  # 2x Next.js images (~1.5GB each)
# NOTE: Typebot requires at least ~12GB disk and 600MB RAM.
#        Recommended: 2GB+ VPS or VPS with larger disk.
#
# Required environment variables (passed by deploy.sh):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS
#   DOMAIN (optional - used to generate builder.$DOMAIN and $DOMAIN)
#
# Optional variables (if you want custom domains):
#   DOMAIN_BUILDER - domain for Builder UI
#   DOMAIN_VIEWER - domain for Viewer

set -e

APP_NAME="typebot"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT_BUILDER=8081
PORT_VIEWER=8082

echo "--- 🤖 Typebot Setup ---"
echo "Requires PostgreSQL Database."

# Check for shared DB (doesn't support gen_random_uuid on PG 12)
if [[ "$DB_HOST" == psql*.mikr.us ]]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ ERROR: Typebot does NOT work with a shared database!     ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Typebot (Prisma) requires gen_random_uuid(), which is not   ║"
    echo "║  available in PostgreSQL 12 (shared database).               ║"
    echo "║                                                              ║"
    echo "║  Solution: Use a dedicated PostgreSQL instance               ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# Validate database credentials
if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
    echo "❌ Error: Missing database credentials!"
    echo "   Required variables: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS"
    exit 1
fi

echo "✅ Database credentials:"
echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"

DB_PORT=${DB_PORT:-5432}
DB_SCHEMA=${DB_SCHEMA:-typebot}

# Build DATABASE_URL with schema support
if [ "$DB_SCHEMA" = "public" ]; then
    DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"
else
    DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME?schema=$DB_SCHEMA"
    echo "   Schema: $DB_SCHEMA"
fi

# Domain configuration
# Typebot requires 2 domains: Builder and Viewer
if [ -n "$DOMAIN_BUILDER" ] && [ -n "$DOMAIN_VIEWER" ]; then
    # Explicit domains provided
    echo "✅ Builder: $DOMAIN_BUILDER"
    echo "✅ Viewer:  $DOMAIN_VIEWER"
elif [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    # Auto-generate from base domain
    DOMAIN_BUILDER="builder.${DOMAIN#builder.}"  # Remove 'builder.' prefix if present
    DOMAIN_VIEWER="${DOMAIN#builder.}"           # Remove 'builder.' prefix if present
    echo "✅ Builder: $DOMAIN_BUILDER (auto)"
    echo "✅ Viewer:  $DOMAIN_VIEWER (auto)"
else
    echo "⚠️  No domains - using localhost"
    DOMAIN_BUILDER=""
    DOMAIN_VIEWER=""
fi

# Generate secret
ENCRYPTION_SECRET=$(openssl rand -hex 32)

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Set URLs based on domain availability
if [ -n "$DOMAIN_BUILDER" ]; then
    NEXTAUTH_URL="https://$DOMAIN_BUILDER"
    VIEWER_URL="https://$DOMAIN_VIEWER"
    ADMIN_EMAIL="admin@$DOMAIN_BUILDER"
else
    NEXTAUTH_URL="http://localhost:$PORT_BUILDER"
    VIEWER_URL="http://localhost:$PORT_VIEWER"
    ADMIN_EMAIL="admin@localhost"
fi

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  typebot-builder:
    image: baptistearno/typebot-builder:latest
    restart: always
    ports:
      - "$PORT_BUILDER:3000"
    environment:
      - DATABASE_URL=$DATABASE_URL
      - NEXTAUTH_URL=$NEXTAUTH_URL
      - NEXT_PUBLIC_VIEWER_URL=$VIEWER_URL
      - ENCRYPTION_SECRET=$ENCRYPTION_SECRET
      - ADMIN_EMAIL=$ADMIN_EMAIL
    depends_on:
      - typebot-viewer
    deploy:
      resources:
        limits:
          memory: 300M

  typebot-viewer:
    image: baptistearno/typebot-viewer:latest
    restart: always
    ports:
      - "$PORT_VIEWER:3000"
    environment:
      - DATABASE_URL=$DATABASE_URL
      - NEXTAUTH_URL=$NEXTAUTH_URL
      - NEXT_PUBLIC_VIEWER_URL=$VIEWER_URL
      - ENCRYPTION_SECRET=$ENCRYPTION_SECRET
    deploy:
      resources:
        limits:
          memory: 300M

EOF

sudo docker compose up -d

# Health check (check both ports)
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT_BUILDER" 60 || { echo "❌ Builder failed to start!"; exit 1; }
    echo "Checking Viewer..."
    curl -s -o /dev/null --max-time 5 "http://localhost:$PORT_VIEWER" && echo "✅ Viewer is responding" || echo "⚠️  Viewer may need more time"
else
    sleep 8
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Typebot containers are running"
    else
        echo "❌ Containers failed to start!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Caddy/HTTPS - only for real domains
if [ -n "$DOMAIN_BUILDER" ] && [ "$DOMAIN_BUILDER" != "-" ] && [[ "$DOMAIN_BUILDER" != *"pending"* ]] && [[ "$DOMAIN_BUILDER" != *"cytrus"* ]]; then
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN_BUILDER" "$PORT_BUILDER"
        sudo sp-expose "$DOMAIN_VIEWER" "$PORT_VIEWER"
    fi
fi

echo ""
echo "✅ Typebot started!"
if [ -n "$DOMAIN_BUILDER" ] && [ "$DOMAIN_BUILDER" != "-" ]; then
    echo "   Builder: https://$DOMAIN_BUILDER"
    echo "   Viewer:  https://$DOMAIN_VIEWER"
elif [ "$DOMAIN_BUILDER" = "-" ]; then
    echo "   Domains will be configured automatically after installation"
else
    echo "   Builder: ssh -L $PORT_BUILDER:localhost:$PORT_BUILDER <server>"
    echo "   Viewer:  ssh -L $PORT_VIEWER:localhost:$PORT_VIEWER <server>"
fi
echo "👉 Note: S3 storage for file uploads is NOT configured in this lite setup."
