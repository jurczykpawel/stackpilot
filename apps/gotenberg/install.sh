#!/bin/bash

# StackPilot - Gotenberg
# API for document conversion (HTML→PDF, DOCX→PDF, etc.)
# Lightweight alternative to Stirling-PDF (~150MB RAM vs ~450MB)
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=1500  # gotenberg/gotenberg:8 (~1.5GB with LibreOffice+Chromium)
#
# Optional environment variables:
#   DOMAIN - domain for Gotenberg
#   GOTENBERG_USER - Basic Auth user (default: admin)
#   GOTENBERG_PASS - Basic Auth password (default: generated)

set -e

APP_NAME="gotenberg"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}

echo "--- 📄 Gotenberg Setup ---"
echo "Lightweight API for document conversion (Go + Chromium + LibreOffice)"

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Cytrus)"
else
    echo "⚠️  No domain - using localhost"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Generate password if not provided
GOTENBERG_USER="${GOTENBERG_USER:-admin}"
if [ -z "$GOTENBERG_PASS" ]; then
    GOTENBERG_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    echo "✅ API password generated"
fi

# Save credentials
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

# Health check (with auth)
sleep 10
if curl -sf -u "$GOTENBERG_USER:$GOTENBERG_PASS" "http://localhost:$PORT/health" > /dev/null 2>&1; then
    echo "✅ Gotenberg is running (with Basic Auth)"
else
    echo "❌ Gotenberg is not responding!"; sudo docker compose logs --tail 20; exit 1
fi

# Caddy/HTTPS - only for real domains
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ] && [[ "$DOMAIN" != *"pending"* ]] && [[ "$DOMAIN" != *"cytrus"* ]]; then
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ Gotenberg started!"
echo ""
echo "🔐 API secured with Basic Auth:"
echo "   User: $GOTENBERG_USER"
echo "   Pass: $GOTENBERG_PASS"
echo "   Credentials: $STACK_DIR/.api_credentials"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 API: https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 API: http://localhost:$PORT"
fi
echo ""
echo "Usage example (with auth):"
echo "  curl -u $GOTENBERG_USER:$GOTENBERG_PASS \\"
echo "    -X POST http://localhost:$PORT/forms/chromium/convert/url \\"
echo "    -F 'url=https://example.com' -o result.pdf"
echo ""
echo "In n8n use: HTTP Request with Basic Auth credentials"
