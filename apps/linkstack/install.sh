#!/bin/bash

# Mikrus Toolbox - LinkStack
# Self-hosted "Link in Bio" page.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=550  # linkstackorg/linkstack:latest
#
# Opcjonalne zmienne środowiskowe:
#   DOMAIN - domena dla LinkStack

set -e

APP_NAME="linkstack"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8090}

echo "--- 🔗 LinkStack Setup ---"

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domena: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domena: automatyczna (Cytrus)"
else
    echo "⚠️  Brak domeny - używam localhost"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Sprawdź czy to pierwsza instalacja (brak plików w data/)
if [ ! -f "./data/index.php" ]; then
    echo "📦 Pierwsza instalacja - pobieram pliki aplikacji..."

    # Tymczasowy kontener bez wolumenu
    cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  linkstack:
    image: linkstackorg/linkstack
    restart: "no"
EOF

    # Uruchom tymczasowo aby skopiować pliki
    sudo docker compose up -d
    sleep 5

    # Skopiuj pliki z kontenera do hosta
    sudo mkdir -p data
    CONTAINER_ID=$(sudo docker compose ps -q linkstack)
    sudo docker cp "$CONTAINER_ID:/htdocs/." ./data/
    sudo docker compose down

    # Ustaw uprawnienia dla Apache
    sudo chown -R 100:101 data
    echo "✅ Pliki aplikacji skopiowane"
fi

# Właściwy docker-compose z bind mount
cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  linkstack:
    image: linkstackorg/linkstack
    restart: always
    ports:
      - "$PORT:80"
    volumes:
      - ./data:/htdocs
    environment:
      - SERVER_ADMIN=admin@localhost
      - TZ=Europe/Warsaw
    deploy:
      resources:
        limits:
          memory: 256M
EOF

sudo docker compose up -d

# Health check
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 45 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ LinkStack działa"
    else
        echo "❌ Kontener nie wystartował!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Caddy/HTTPS - only for real domains
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ] && [[ "$DOMAIN" != *"pending"* ]] && [[ "$DOMAIN" != *"cytrus"* ]]; then
    if command -v mikrus-expose &> /dev/null; then
        sudo mikrus-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ LinkStack started!"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Otwórz: https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Dostęp przez tunel SSH: ssh -L $PORT:localhost:$PORT <server>"
    echo "   Potem otwórz: http://localhost:$PORT"
fi
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📋 SETUP WIZARD - co wybrać?"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "   🎯 Jesteś soloprenerem / masz jeden profil?"
echo "      → Wybierz SQLite i nie myśl więcej"
echo ""
echo "   🏢 Robisz to dla firmy z wieloma pracownikami?"
echo "      → MySQL (dane: ssh $SSH_ALIAS 'curl -s -d"
echo "        \"srv=\\\$(hostname)&key=\\\$(cat /klucz_api)\" https://api.mikr.us/db.bash')"
echo ""
echo "   📝 Zapisz dane logowania admina - będą potrzebne później!"
echo ""
