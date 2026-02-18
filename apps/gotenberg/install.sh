#!/bin/bash

# Mikrus Toolbox - Gotenberg
# API do konwersji dokumentów (HTML→PDF, DOCX→PDF, itp.)
# Lekka alternatywa dla Stirling-PDF (~150MB RAM vs ~450MB)
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=1500  # gotenberg/gotenberg:8 (~1.5GB z LibreOffice+Chromium)
#
# Opcjonalne zmienne środowiskowe:
#   DOMAIN - domena dla Gotenberg
#   GOTENBERG_USER - użytkownik Basic Auth (domyślnie: admin)
#   GOTENBERG_PASS - hasło Basic Auth (domyślnie: generowane)

set -e

APP_NAME="gotenberg"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}

echo "--- 📄 Gotenberg Setup ---"
echo "Lekkie API do konwersji dokumentów (Go + Chromium + LibreOffice)"

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

# Generuj hasło jeśli nie podano
GOTENBERG_USER="${GOTENBERG_USER:-admin}"
if [ -z "$GOTENBERG_PASS" ]; then
    GOTENBERG_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    echo "✅ Wygenerowano hasło API"
fi

# Zapisz credentials
echo "$GOTENBERG_USER:$GOTENBERG_PASS" | sudo tee .api_credentials > /dev/null
sudo chmod 600 .api_credentials

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  gotenberg:
    image: gotenberg/gotenberg:8
    restart: always
    ports:
      - "$PORT:3000"
    environment:
      - GOTENBERG_API_BASIC_AUTH_USERNAME=$GOTENBERG_USER
      - GOTENBERG_API_BASIC_AUTH_PASSWORD=$GOTENBERG_PASS
    command:
      - "gotenberg"
      - "--api-enable-basic-auth"
      - "--chromium-disable-javascript=true"
      - "--chromium-allow-list=file:///tmp/.*"
    deploy:
      resources:
        limits:
          memory: 256M

EOF

sudo docker compose up -d

# Health check (z auth)
sleep 10
if curl -sf -u "$GOTENBERG_USER:$GOTENBERG_PASS" "http://localhost:$PORT/health" > /dev/null 2>&1; then
    echo "✅ Gotenberg działa (z Basic Auth)"
else
    echo "❌ Gotenberg nie odpowiada!"; sudo docker compose logs --tail 20; exit 1
fi

# Caddy/HTTPS - only for real domains
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ] && [[ "$DOMAIN" != *"pending"* ]] && [[ "$DOMAIN" != *"cytrus"* ]]; then
    if command -v mikrus-expose &> /dev/null; then
        sudo mikrus-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ Gotenberg started!"
echo ""
echo "🔐 API zabezpieczone Basic Auth:"
echo "   User: $GOTENBERG_USER"
echo "   Pass: $GOTENBERG_PASS"
echo "   Credentials: $STACK_DIR/.api_credentials"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 API: https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domena zostanie skonfigurowana automatycznie po instalacji"
else
    echo "🔗 API: http://localhost:$PORT"
fi
echo ""
echo "Przykład użycia (z auth):"
echo "  curl -u $GOTENBERG_USER:$GOTENBERG_PASS \\"
echo "    -X POST http://localhost:$PORT/forms/chromium/convert/url \\"
echo "    -F 'url=https://example.com' -o result.pdf"
echo ""
echo "W n8n użyj: HTTP Request z Basic Auth credentials"

