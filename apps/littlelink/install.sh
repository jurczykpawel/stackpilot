#!/bin/bash

# StackPilot - LittleLink
# Link-in-bio page (Linktree alternative).
# Supports both Docker (Cytrus) and Caddy (Cloudflare) modes.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=50  # nginx:alpine (only for Docker mode)

set -e

APP_NAME="littlelink"
echo "--- LittleLink Setup ---"

# Required: DOMAIN
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "-" ]; then
    echo "Brak wymaganej zmiennej: DOMAIN"
    echo "   Uzycie: DOMAIN=bio.example.com ./install.sh"
    exit 1
fi
echo "Domena: $DOMAIN"

# Detect domain type: Cytrus (*.byst.re, *.mikr.us) vs Cloudflare
is_cytrus_domain() {
    case "$1" in
        *.byst.re|*.mikr.us|*.srv24.pl|*.vxm.pl) return 0 ;;
        *) return 1 ;;
    esac
}

# Prerequisites
if ! command -v git &> /dev/null; then
    echo "Installing git..."
    sudo apt update && sudo apt install -y git
fi

if is_cytrus_domain "$DOMAIN"; then
    # === CYTRUS MODE: Docker + nginx ===
    echo "Tryb: Cytrus (Docker + nginx)"

    STACK_DIR="/opt/stacks/$APP_NAME"
    PORT="${PORT:-8090}"

    sudo mkdir -p "$STACK_DIR/public"
    cd "$STACK_DIR"

    # Download LittleLink
    if [ -d "public/.git" ] || [ -f "public/index.html" ]; then
        echo "LittleLink juz zainstalowany. Pomijam pobieranie."
    else
        sudo git clone --depth 1 https://github.com/sethcottle/littlelink.git public_tmp
        sudo mv public_tmp/* public/
        sudo rm -rf public_tmp
    fi

    # Docker Compose
    cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  littlelink:
    image: nginx:alpine
    restart: always
    ports:
      - "$PORT:80"
    volumes:
      - ./public:/usr/share/nginx/html:ro
    deploy:
      resources:
        limits:
          memory: 32M

EOF

    sudo docker compose up -d

    # Health check
    sleep 3
    if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
        echo "LittleLink dziala na porcie $PORT"
    else
        echo "Blad uruchomienia!"; sudo docker compose logs --tail 10; exit 1
    fi

    # Zapisz port dla deploy.sh (do konfiguracji domeny)
    echo "$PORT" > /tmp/app_port

    echo ""
    echo "LittleLink started!"
    echo "   Port: $PORT"
    echo "   Files: $STACK_DIR/public/"
    echo ""
    echo "Edycja: nano $STACK_DIR/public/index.html"

else
    # === CLOUDFLARE MODE: Caddy file_server ===
    echo "Tryb: Cloudflare (Caddy file_server)"

    if ! command -v caddy &> /dev/null; then
        echo "Caddy nie zainstalowany. Uruchom system/caddy-install.sh"
        exit 1
    fi

    WEB_ROOT="/var/www/$APP_NAME"

    # Download LittleLink
    sudo mkdir -p "$WEB_ROOT"
    if [ -d "$WEB_ROOT/.git" ] || [ -f "$WEB_ROOT/index.html" ]; then
        echo "LittleLink juz zainstalowany. Pomijam pobieranie."
    else
        sudo git clone --depth 1 https://github.com/sethcottle/littlelink.git "$WEB_ROOT"
        sudo rm -rf "$WEB_ROOT/.git"
    fi

    # Caddy will be configured by sp-expose (called from deploy.sh)
    # Just store the path for later
    echo "$WEB_ROOT" > /tmp/littlelink_webroot

    echo ""
    echo "LittleLink installed!"
    echo "   Files: $WEB_ROOT"
    echo ""
    echo "Edycja: nano $WEB_ROOT/index.html"
fi
