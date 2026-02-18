#!/bin/bash

# Mikrus Toolbox - FileBrowser
# Web-based File Manager + Static Hosting (Tiiny.host Killer!)
# Supports both Cytrus (nginx) and Cloudflare (Caddy) modes.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=40  # filebrowser/filebrowser + nginx:alpine (~70MB total)
#
# Zmienne środowiskowe:
#   DOMAIN - domena dla File Manager (admin panel)
#   DOMAIN_PUBLIC - domena dla public static hosting (opcjonalne)
#   PORT - port dla FileBrowser (domyślnie 8095)
#   PORT_PUBLIC - port dla static hosting (domyślnie 8096)

set -e

APP_NAME="filebrowser"
STACK_DIR="/opt/stacks/$APP_NAME"
DATA_DIR="/var/www/public"
PORT=${PORT:-8095}
PORT_PUBLIC=${PORT_PUBLIC:-8096}

echo "--- 📂 FileBrowser Setup ---"
echo ""
echo "Instaluję:"
echo "  • FileBrowser (panel zarządzania plikami)"
echo "  • Static Hosting (publiczne pliki - Tiiny.host killer)"
echo ""
echo "Pliki: $DATA_DIR"

# Detect domain type: Cytrus (*.byst.re, etc.) vs Cloudflare
is_cytrus_domain() {
    case "$1" in
        *.byst.re|*.bieda.it|*.toadres.pl|*.tojest.dev|*.mikr.us|*.srv24.pl|*.vxm.pl) return 0 ;;
        *) return 1 ;;
    esac
}

# Domain for admin panel
DOMAIN_ADMIN="${DOMAIN_ADMIN:-$DOMAIN}"
if [ -n "$DOMAIN_ADMIN" ]; then
    echo "✅ Admin Panel: $DOMAIN_ADMIN (port $PORT)"
fi

# Domain for public static hosting
if [ -n "$DOMAIN_PUBLIC" ]; then
    echo "✅ Public Hosting: $DOMAIN_PUBLIC (port $PORT_PUBLIC)"
fi

echo ""

# =============================================================================
# 1. PREPARE DIRECTORIES
# =============================================================================

sudo mkdir -p "$STACK_DIR"
sudo mkdir -p "$DATA_DIR"
sudo chown -R 1000:1000 "$DATA_DIR"
sudo chmod -R o+rX "$DATA_DIR"  # Ensure nginx can read
cd "$STACK_DIR"

# Create DB file (FileBrowser needs it to exist)
if [ ! -f filebrowser.db ]; then
    touch filebrowser.db
    chmod 666 filebrowser.db
fi

# =============================================================================
# 2. DOCKER COMPOSE - depends on domain type
# =============================================================================

if [ -n "$DOMAIN_PUBLIC" ] && is_cytrus_domain "$DOMAIN_PUBLIC"; then
    # === CYTRUS MODE: FileBrowser + nginx for static files ===
    echo "🍊 Tryb Cytrus: nginx dla plików statycznych"

    cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  filebrowser:
    image: filebrowser/filebrowser:latest
    restart: always
    ports:
      - "$PORT:80"
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

  static:
    image: nginx:alpine
    restart: always
    ports:
      - "$PORT_PUBLIC:80"
    volumes:
      - $DATA_DIR:/usr/share/nginx/html:ro
    deploy:
      resources:
        limits:
          memory: 32M

EOF

else
    # === CLOUDFLARE MODE: Only FileBrowser (Caddy serves static) ===
    echo "☁️  Tryb Cloudflare: Caddy dla plików statycznych"

    cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  filebrowser:
    image: filebrowser/filebrowser:latest
    restart: always
    ports:
      - "$PORT:80"
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
fi

# =============================================================================
# 3. START CONTAINERS
# =============================================================================

echo ""
echo "🚀 Uruchamiam kontenery..."
sudo docker compose pull --quiet
sudo docker compose up -d

# Health check
sleep 3
if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
    echo "✅ FileBrowser działa na porcie $PORT"
else
    echo "❌ FileBrowser nie odpowiada!"
    sudo docker compose logs --tail 10
    exit 1
fi

if [ -n "$DOMAIN_PUBLIC" ] && is_cytrus_domain "$DOMAIN_PUBLIC"; then
    if curl -sf "http://localhost:$PORT_PUBLIC" > /dev/null 2>&1; then
        echo "✅ Static Server działa na porcie $PORT_PUBLIC"
    else
        echo "⚠️  Static Server jeszcze startuje..."
    fi
fi

# Save port for deploy.sh
echo "$PORT" > /tmp/app_port

# =============================================================================
# 4. SUMMARY
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ FileBrowser zainstalowany!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "📁 Panel Admin (wymaga logowania):"
if [ -n "$DOMAIN_ADMIN" ] && [ "$DOMAIN_ADMIN" != "-" ]; then
    echo "   https://$DOMAIN_ADMIN"
elif [ "$DOMAIN_ADMIN" = "-" ]; then
    echo "   (domena zostanie skonfigurowana automatycznie)"
else
    echo "   http://localhost:$PORT (użyj tunelu SSH)"
fi
echo "   👤 Login: admin / admin"
echo "   ⚠️  ZMIEŃ HASŁO PO PIERWSZYM LOGOWANIU!"
echo ""

if [ -n "$DOMAIN_PUBLIC" ]; then
    echo "🌍 Public Hosting (dostępne publicznie):"
    echo "   https://$DOMAIN_PUBLIC"
    echo ""
    echo "   Przykład: wrzuć ebook.pdf → https://$DOMAIN_PUBLIC/ebook.pdf"
fi

echo ""
echo "📂 Pliki przechowywane w: $DATA_DIR"
echo ""
