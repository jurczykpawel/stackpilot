#!/bin/bash

# StackPilot - FileBrowser
# Web-based File Manager + Static Hosting (Tiiny.host Killer!)
# Uses Caddy for static file serving (no nginx container needed).
# Author: Pawel (Lazy Engineer)
#
# IMAGE_SIZE_MB=40  # filebrowser/filebrowser
#
# Environment variables:
#   DOMAIN - domain for File Manager (admin panel)
#   DOMAIN_PUBLIC - domain for public static hosting (optional)
#   PORT - port for FileBrowser (default 8095)

set -e

APP_NAME="filebrowser"
STACK_DIR="/opt/stacks/$APP_NAME"
DATA_DIR="/var/www/public"
PORT=${PORT:-8095}

echo "--- FileBrowser Setup ---"
echo ""
echo "Installing:"
echo "  FileBrowser (file management panel)"
echo "  Static Hosting (public files - Tiiny.host killer)"
echo ""
echo "Files: $DATA_DIR"

# Domain for admin panel
DOMAIN_ADMIN="${DOMAIN_ADMIN:-$DOMAIN}"
if [ -n "$DOMAIN_ADMIN" ]; then
    echo "Admin Panel: $DOMAIN_ADMIN (port $PORT)"
fi

# Domain for public static hosting
if [ -n "$DOMAIN_PUBLIC" ]; then
    echo "Public Hosting: $DOMAIN_PUBLIC (via Caddy)"
fi

echo ""

# =============================================================================
# 1. PREPARE DIRECTORIES
# =============================================================================

sudo mkdir -p "$STACK_DIR"
sudo mkdir -p "$DATA_DIR"
sudo chown -R 1000:1000 "$DATA_DIR"
sudo chmod -R o+rX "$DATA_DIR"  # Ensure Caddy can read
cd "$STACK_DIR"

# Create DB file (FileBrowser needs it to exist)
if [ ! -f filebrowser.db ]; then
    touch filebrowser.db
    chmod 666 filebrowser.db
fi

# =============================================================================
# 2. DOCKER COMPOSE - Only FileBrowser (Caddy serves static files)
# =============================================================================

echo "Caddy mode: Caddy for static files"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  filebrowser:
    image: filebrowser/filebrowser:latest
    restart: always
    ports:
      - "127.0.0.1:$PORT:80"
    volumes:
      - $DATA_DIR:/srv
      - ./filebrowser.db:/database.db
    environment:
      - FB_DATABASE=/database.db
      - FB_ROOT=/srv
    deploy:
      resources:
        limits:
          memory: 128M

EOF

# Save webroot for DOMAIN_PUBLIC Caddy configuration (used by deploy.sh)
# Note: This file is read by deploy.sh for DOMAIN_PUBLIC, not for main DOMAIN
if [ -n "$DOMAIN_PUBLIC" ]; then
    echo "$DATA_DIR" > /tmp/domain_public_webroot
fi

# =============================================================================
# 3. START CONTAINERS
# =============================================================================

echo ""
echo "Starting containers..."
sudo docker compose pull --quiet
sudo docker compose up -d

# Health check
sleep 3
if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
    echo "FileBrowser is running on port $PORT"
else
    echo "FileBrowser is not responding!"
    sudo docker compose logs --tail 10
    exit 1
fi

# Save port for deploy.sh
echo "$PORT" > /tmp/app_port

# =============================================================================
# 4. SUMMARY
# =============================================================================

echo ""
echo "FileBrowser installed!"
echo ""
echo "Admin Panel (requires login):"
if [ -n "$DOMAIN_ADMIN" ]; then
    echo "   https://$DOMAIN_ADMIN"
else
    echo "   http://localhost:$PORT (use SSH tunnel)"
fi
echo "   Login: admin / admin"
echo "   CHANGE PASSWORD AFTER FIRST LOGIN!"
echo ""

if [ -n "$DOMAIN_PUBLIC" ]; then
    echo "Public Hosting (publicly accessible):"
    echo "   https://$DOMAIN_PUBLIC"
    echo ""
    echo "   Example: upload ebook.pdf -> https://$DOMAIN_PUBLIC/ebook.pdf"
fi

echo ""
echo "Files stored in: $DATA_DIR"
echo ""
