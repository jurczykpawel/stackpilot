#!/bin/bash

# Mikrus Toolbox - Stirling-PDF
# Your local, privacy-friendly PDF Swiss Army Knife.
# Merge, Split, Convert, OCR - all in your browser.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=1000  # frooodle/s-pdf:latest (~1GB z Java+LibreOffice)
#
# ⚠️  UWAGA: Ta aplikacja wymaga minimum 2GB RAM (Mikrus 3.0+)!
#     Stirling-PDF używa Java (Spring Boot) + LibreOffice do konwersji.
#     Na Mikrus 2.1 (1GB RAM) może powodować zawieszenie serwera.
#
# Opcjonalne zmienne środowiskowe:
#   DOMAIN - domena dla Stirling-PDF

set -e

APP_NAME="stirling-pdf"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8087}

echo "--- 📄 Stirling-PDF Setup ---"

# Sprawdź dostępny RAM - WYMAGANE minimum 2GB!
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")

if [ "$TOTAL_RAM" -lt 1800 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ BŁĄD: Za mało RAM dla Stirling-PDF!                        ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Twój serwer: ${TOTAL_RAM}MB RAM                                        ║"
    echo "║  Wymagane:    2048MB RAM (Mikrus 3.0+)                         ║"
    echo "║                                                                ║"
    echo "║  Stirling-PDF używa Java + LibreOffice (~600-800MB RAM).      ║"
    echo "║  Na Mikrus 2.1 zawiesza serwer!                               ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  💡 ALTERNATYWA: Gotenberg                                     ║"
    echo "║     Lekkie API do konwersji dokumentów (~150MB RAM)           ║"
    echo "║     Instalacja: ./local/deploy.sh gotenberg                   ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# Ustaw limit pamięci kontenera w zależności od dostępnego RAM
if [ "$TOTAL_RAM" -ge 3000 ]; then
    MEMORY_LIMIT="1536M"
    echo "✅ RAM: ${TOTAL_RAM}MB - limit kontenera: 1.5GB"
else
    MEMORY_LIMIT="1024M"
    echo "✅ RAM: ${TOTAL_RAM}MB - limit kontenera: 1GB"
fi
echo ""

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

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  stirling-pdf:
    image: frooodle/s-pdf:latest
    restart: always
    ports:
      - "$PORT:8080"
    environment:
      - DOCKER_ENABLE_SECURITY=false
    volumes:
      - ./data:/configs
    deploy:
      resources:
        limits:
          memory: $MEMORY_LIMIT

EOF

sudo docker compose up -d

# Health check - Stirling-PDF potrzebuje ~90-120s na start (Java + LibreOffice)
echo "⏳ Czekam na uruchomienie Stirling-PDF (~90s dla Java)..."
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 120 || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    # Fallback - czekaj do 120s
    for i in $(seq 1 12); do
        sleep 10
        if curl -sf "http://localhost:$PORT" > /dev/null 2>&1 || curl -sf "http://localhost:$PORT/login" > /dev/null 2>&1; then
            echo "✅ Stirling-PDF działa (po $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 12 ]; then
            echo "❌ Kontener nie wystartował w 120s!"
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

# Caddy/HTTPS - only for real domains
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ] && [[ "$DOMAIN" != *"pending"* ]] && [[ "$DOMAIN" != *"cytrus"* ]]; then
    if command -v mikrus-expose &> /dev/null; then
        sudo mikrus-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ Stirling-PDF started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
