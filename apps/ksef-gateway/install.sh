#!/bin/bash

# StackPilot - KSeF Gateway
# Universal REST API gateway for Poland's National e-Invoice System (KSeF).
# Send invoices, get PDFs with QR codes - one HTTP call.
# https://github.com/jurczykpawel/ksef-gateway
#
# IMAGE_SIZE_MB=600  # ksef-gateway-api (~400MB) + ksef-gateway-pdf (~200MB)
#
# Required environment variables (passed by deploy.sh or --yes mode):
#   KSEF_TOKEN  - KSeF authentication token (generate at https://github.com/jurczykpawel/ksef-gateway#how-token-generator-works)
#   KSEF_NIP    - NIP for KSeF authentication context
#
# Optional:
#   KSEF_ENV    - KSeF environment: TEST (default), DEMO, PRODUCTION
#   PORT        - API port (default: 8080)

set -e

APP_NAME="ksef-gateway"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8080}
KSEF_ENV=${KSEF_ENV:-TEST}

echo "--- KSeF Gateway Setup ---"
echo ""

# 1. Validate credentials
if [ -z "$KSEF_TOKEN" ] || [ -z "$KSEF_NIP" ]; then
    echo "Missing KSeF credentials!"
    echo ""
    echo "  Required: KSEF_TOKEN, KSEF_NIP"
    echo ""
    echo "  Generate a test token:"
    echo "    git clone --recurse-submodules https://github.com/jurczykpawel/ksef-gateway.git"
    echo "    cd ksef-gateway"
    echo "    docker compose --profile tools run --rm token-generator"
    echo ""
    echo "  Then deploy with:"
    echo "    KSEF_TOKEN=... KSEF_NIP=... ./local/deploy.sh ksef-gateway --ssh=vps"
    exit 1
fi

echo "NIP: $KSEF_NIP"
echo "Environment: $KSEF_ENV"
echo "Port: $PORT"
echo ""

# 2. Prepare directory
sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# 3. Create docker-compose.yaml
cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  ksef-api:
    image: ghcr.io/jurczykpawel/ksef-gateway-api:latest
    restart: always
    ports:
      - "127.0.0.1:$PORT:8080"
    environment:
      - KSEF_TOKEN=$KSEF_TOKEN
      - KSEF_NIP=$KSEF_NIP
      - KSEF_ENV=$KSEF_ENV
      - PDF_SERVICE_URL=http://ksef-pdf:3000
    depends_on:
      ksef-pdf:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 384M

  ksef-pdf:
    image: ghcr.io/jurczykpawel/ksef-gateway-pdf:latest
    restart: always
    expose:
      - "3000"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:3000/health"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 192M
EOF

# 4. Pull images and start
echo "Pulling images..."
sudo docker compose pull

echo "Starting KSeF Gateway..."
sudo docker compose up -d

# 5. Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 45 "/health" || {
        echo "KSeF Gateway failed to start!"
        echo "Logs:"
        sudo docker compose logs --tail=30
        exit 1
    }
else
    echo "Waiting for startup..."
    sleep 10
    if sudo docker compose ps --format json 2>/dev/null | grep -q '"State":"running"'; then
        echo "KSeF Gateway is running!"
    else
        echo "KSeF Gateway failed to start!"
        sudo docker compose logs --tail=30
        exit 1
    fi
fi

echo ""
echo "KSeF Gateway deployed!"
echo ""
echo "  API:  http://localhost:$PORT"
echo "  Docs: http://localhost:$PORT/scalar/v1"
echo ""
echo "  Test: curl http://localhost:$PORT/health"
echo "  Send: curl -X POST http://localhost:$PORT/ksef/send -H 'Content-Type: application/xml' -d @invoice.xml"
