#!/bin/bash

# StackPilot - Cap (Open Source Loom Alternative)
# Record, edit and share video in seconds.
# https://github.com/CapSoftware/Cap
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=1500  # cap-web ~1.5GB (z MinIO/MySQL może być więcej)
# NOTE: Cap requires MySQL + S3/MinIO. With local containers it needs:
#        - ~1.5GB+ RAM (cap 512MB + MySQL 512MB + MinIO 256MB)
#        - ~4GB disk space for images
#        Recommended: 2GB+ VPS

set -e

APP_NAME="cap"
STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
source "${STACKPILOT_LIB:-/opt/stackpilot/lib}/stack-config.sh"
PORT=${PORT:-3000}

# Port binding: Cytrus needs 0.0.0.0, Cloudflare/Caddy/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

echo "--- 🎬 Cap Setup (Loom Alternative) ---"
echo "Cap lets you record your screen and share videos."
echo ""

# Required: DOMAIN
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "-" ]; then
    echo "❌ Missing required variable: DOMAIN"
    echo ""
    echo "   Usage (external database + external S3):"
    echo "   DB_HOST=mysql.example.com DB_PORT=3306 DB_NAME=cap \\"
    echo "   DB_USER=myuser DB_PASS=secret \\"
    echo "   S3_ENDPOINT=https://xxx.r2.cloudflarestorage.com \\"
    echo "   S3_PUBLIC_URL=https://cdn.example.com \\"
    echo "   S3_REGION=auto S3_BUCKET=cap-videos \\"
    echo "   S3_ACCESS_KEY=xxx S3_SECRET_KEY=yyy \\"
    echo "   DOMAIN=cap.example.com ./install.sh"
    echo ""
    echo "   Usage (local database + local MinIO):"
    echo "   MYSQL_ROOT_PASS=secret USE_LOCAL_MINIO=true \\"
    echo "   DOMAIN=cap.example.com ./install.sh"
    exit 1
fi

echo "✅ Domain: $DOMAIN"

# 1. MySQL database configuration
echo "=== MySQL Configuration ==="

if [ -n "$DB_HOST" ] && [ -n "$DB_USER" ]; then
    # External MySQL database
    echo "✅ Using external MySQL database:"
    echo "   Host: $DB_HOST | User: $DB_USER | DB: $DB_NAME"
    DB_PORT=${DB_PORT:-3306}
    DATABASE_URL="mysql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    USE_LOCAL_MYSQL="false"
elif [ -n "$MYSQL_ROOT_PASS" ]; then
    # Local MySQL database
    echo "✅ Using local MySQL database (container)"
    MYSQL_DB="cap"
    DATABASE_URL="mysql://root:${MYSQL_ROOT_PASS}@cap-mysql:3306/${MYSQL_DB}"
    USE_LOCAL_MYSQL="true"
else
    echo "❌ Missing MySQL configuration!"
    echo "   Option 1 (external): DB_HOST, DB_USER, DB_PASS, DB_NAME"
    echo "   Option 2 (local): MYSQL_ROOT_PASS"
    exit 1
fi

# 2. S3 Storage configuration
echo ""
echo "=== Storage Configuration (S3) ==="

if [ -n "$S3_ENDPOINT" ] && [ -n "$S3_ACCESS_KEY" ]; then
    # External S3
    echo "✅ Using external S3:"
    echo "   Endpoint: $S3_ENDPOINT | Bucket: $S3_BUCKET"
    USE_LOCAL_MINIO="false"
elif [ "$USE_LOCAL_MINIO" == "true" ]; then
    # Local MinIO
    echo "✅ Using local MinIO (container)"
    S3_ACCESS_KEY=$(stack_value "$STACK_DIR/docker-compose.yaml" MINIO_ROOT_USER || echo "cap-$(openssl rand -hex 6)")
    S3_SECRET_KEY=$(stack_value "$STACK_DIR/docker-compose.yaml" MINIO_ROOT_PASSWORD || openssl rand -hex 24)
    S3_BUCKET="cap-videos"
    S3_REGION="us-east-1"
    S3_ENDPOINT="http://cap-minio:9000"
    S3_PUBLIC_URL="https://${DOMAIN}:3902"
    echo "⚠️  MinIO will be available on port 3902"
else
    echo "❌ Missing S3 configuration!"
    echo "   Option 1 (external): S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY, S3_BUCKET, S3_REGION, S3_PUBLIC_URL"
    echo "   Option 2 (local): USE_LOCAL_MINIO=true"
    exit 1
fi

# Generate secrets
echo ""
echo "Generating security keys..."
NEXTAUTH_SECRET=$(stack_value "$STACK_DIR/docker-compose.yaml" NEXTAUTH_SECRET || openssl rand -base64 32)
DATABASE_ENCRYPTION_KEY=$(stack_value "$STACK_DIR/docker-compose.yaml" DATABASE_ENCRYPTION_KEY || openssl rand -base64 32)

# 4. Prepare directory
sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# 5. Generate docker-compose.yaml
echo "--- Creating Docker configuration ---"

cat <<EOF | sudo tee docker-compose.yaml

services:
  cap-web:
    image: ghcr.io/capsoftware/cap-web:latest
    restart: unless-stopped
    ports:
      - "${BIND_ADDR}${PORT}:3000"
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - WEB_URL=https://${DOMAIN}
      - NEXTAUTH_URL=https://${DOMAIN}
      - NEXTAUTH_SECRET=${NEXTAUTH_SECRET}
      - DATABASE_ENCRYPTION_KEY=${DATABASE_ENCRYPTION_KEY}
      - CAP_AWS_ACCESS_KEY=${S3_ACCESS_KEY}
      - CAP_AWS_SECRET_KEY=${S3_SECRET_KEY}
      - CAP_AWS_BUCKET=${S3_BUCKET}
      - CAP_AWS_REGION=${S3_REGION}
      - S3_PUBLIC_ENDPOINT=${S3_PUBLIC_URL}
      - S3_INTERNAL_ENDPOINT=${S3_ENDPOINT}
EOF

# Add local services if needed
if [ "$USE_LOCAL_MYSQL" == "true" ]; then
cat <<EOF | sudo tee -a docker-compose.yaml
    depends_on:
      - cap-mysql

  cap-mysql:
    image: mysql:8.0
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
      - MYSQL_DATABASE=${MYSQL_DB}
    volumes:
      - ./mysql-data:/var/lib/mysql
    deploy:
      resources:
        limits:
          memory: 512M
EOF
fi

if [ "$USE_LOCAL_MINIO" == "true" ]; then
cat <<EOF | sudo tee -a docker-compose.yaml

  cap-minio:
    image: pgsty/silo:RELEASE.2026-11-12T00-00-00Z
    command: server /data --console-address ":9001"
    restart: unless-stopped
    ports:
      - "127.0.0.1:3902:9000"
      - "127.0.0.1:3903:9001"
    environment:
      - MINIO_ROOT_USER=${S3_ACCESS_KEY}
      - MINIO_ROOT_PASSWORD=${S3_SECRET_KEY}
    volumes:
      - ./minio-data:/data
    deploy:
      resources:
        limits:
          memory: 256M
EOF
fi

# Append bundled database service if using bundled DB
if [ -n "$BUNDLED_DB_TYPE" ]; then
    # Add depends_on to main service (first occurrence only)
    sudo sed -i '0,/restart: unless-stopped/s/restart: unless-stopped/restart: unless-stopped\n    depends_on:\n      - db/' docker-compose.yaml

    if [ "$BUNDLED_DB_TYPE" = "mysql" ]; then
        cat <<DBEOF | sudo tee -a docker-compose.yaml > /dev/null
  db:
    image: mysql:8.0
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASS}
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASS}
    volumes:
      - db-data:/var/lib/mysql
    deploy:
      resources:
        limits:
          memory: 256M

volumes:
  db-data:
DBEOF
    fi
fi

# Bind mounts are used instead of named volumes - data in /opt/stacks/cap/
# This way backup automatically includes mysql-data/ and minio-data/

# Memory limit dla cap-web
sudo sed -i '/cap-web:/,/environment:/{ /image:/a\    deploy:\n      resources:\n        limits:\n          memory: 512M' docker-compose.yaml 2>/dev/null || true

echo ""
echo "--- Starting Cap ---"
sudo docker compose up -d

# Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 90 || { echo "❌ Installation failed!"; exit 1; }
else
    sleep 10
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Cap is running"
    else
        echo "❌ Container failed to start!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Create MinIO bucket if using local MinIO
if [ "$USE_LOCAL_MINIO" == "true" ]; then
    echo ""
    echo "--- Creating MinIO bucket ---"
    sleep 3  # Wait for MinIO to start

    # MinIO automatically creates the bucket on first use by Cap
    # Alternatively you can use mc client installed on the host:
    # mc alias set cap-minio http://localhost:3902 ${S3_ACCESS_KEY} ${S3_SECRET_KEY}
    # mc mb cap-minio/${S3_BUCKET}
    echo "ℹ️  Bucket will be created automatically on first use"
fi

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo ""
    echo "--- Configuring HTTPS via Caddy ---"
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    else
        echo "⚠️  'sp-expose' not found. Install Caddy: system/caddy-install.sh"
        echo "   Or configure reverse proxy manually on port $PORT"
    fi
fi

if [ "$USE_LOCAL_MINIO" == "true" ]; then
    echo ""
    echo "⚠️  MinIO requires separate proxy configuration for port 3902"
    echo "   Or configure external S3 (Cloudflare R2, AWS S3, etc.)"
fi

echo ""
echo "============================================"
echo "✅ Cap installed!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN to get started"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo ""
echo "📝 Save these credentials in a secure location:"
echo "   NEXTAUTH_SECRET: $NEXTAUTH_SECRET"
echo "   DATABASE_ENCRYPTION_KEY: $DATABASE_ENCRYPTION_KEY"
if [ "$USE_LOCAL_MINIO" == "true" ]; then
    echo "   MinIO access key: $S3_ACCESS_KEY"
    echo "   MinIO secret key: $S3_SECRET_KEY"
fi
echo "============================================"
