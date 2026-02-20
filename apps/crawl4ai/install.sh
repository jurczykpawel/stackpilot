#!/bin/bash

# StackPilot - Crawl4AI
# AI-powered web crawler and scraper with REST API.
# Extract structured data from any website using LLMs.
# https://github.com/unclecode/crawl4ai
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=3500  # unclecode/crawl4ai:latest (1.4GB compressed → ~3.5GB on disk)
#
# ⚠️  NOTE: This app requires at least 2GB RAM (2GB+ VPS)!
#     Crawl4AI runs headless Chromium for crawling pages.
#     On a 1GB VPS it may cause the server to hang.
#
# Known issue: memory leak under heavy use (Chrome processes accumulate).
# PLAYWRIGHT_MAX_CONCURRENCY=2 limits this, but under heavy traffic consider a cron restart.

set -e

APP_NAME="crawl4ai"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8000}

echo "--- 🕷️ Crawl4AI Setup ---"
echo "AI-powered web crawler with REST API."
echo ""

# Port binding: always bind to 127.0.0.1 (Caddy handles public exposure)
BIND_ADDR="127.0.0.1:"

# Check available RAM - REQUIRED minimum 2GB!
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 1800 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ ERROR: Not enough RAM for Crawl4AI!                      ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Your server: ${TOTAL_RAM}MB RAM                             ║"
    echo "║  Required:    2048MB RAM (2GB+ VPS)                          ║"
    echo "║                                                              ║"
    echo "║  Crawl4AI runs headless Chromium (~1-1.5GB RAM).             ║"
    echo "║  On a 1GB VPS it hangs the server!                           ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Cytrus)"
else
    echo "⚠️  No domain - use --domain=... or access via SSH tunnel"
fi

# Generate API token
CRAWL4AI_API_TOKEN=$(openssl rand -hex 32)

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Save token
echo "$CRAWL4AI_API_TOKEN" | sudo tee .api_token > /dev/null
sudo chmod 600 .api_token
echo "✅ API token generated and saved"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  crawl4ai:
    image: unclecode/crawl4ai:latest
    restart: always
    user: "1000:1000"
    ports:
      - "${BIND_ADDR}$PORT:11235"
    environment:
      - CRAWL4AI_API_TOKEN=$CRAWL4AI_API_TOKEN
      - CRAWL4AI_MODE=api
      - PLAYWRIGHT_MAX_CONCURRENCY=2
    shm_size: "1g"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11235/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: 1536M
EOF

sudo docker compose up -d

# Health check - Chromium needs a lot of time to start
echo "⏳ Waiting for Crawl4AI to start (~60-90s, Chromium is loading)..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 90 || { echo "❌ Installation failed!"; exit 1; }
else
    for i in $(seq 1 9); do
        sleep 10
        if curl -sf "http://localhost:$PORT/health" > /dev/null 2>&1; then
            echo "✅ Crawl4AI is running (after $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 9 ]; then
            echo "❌ Container failed to start within 90s!"
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ Crawl4AI installed!"
echo "════════════════════════════════════════════════════════════════"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 API: https://$DOMAIN"
    echo "🔗 Playground: https://$DOMAIN/playground"
    echo "🔗 Monitor: https://$DOMAIN/monitor"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
    echo "   API: http://localhost:$PORT"
    echo "   Playground: http://localhost:$PORT/playground"
    echo "   Monitor: http://localhost:$PORT/monitor"
fi
echo ""
echo "🔑 API Token: $CRAWL4AI_API_TOKEN"
echo "   Saved in: $STACK_DIR/.api_token"
echo ""
echo "📋 Usage example:"
echo "   curl -X POST http://localhost:$PORT/crawl \\"
echo "     -H 'Authorization: Bearer $CRAWL4AI_API_TOKEN' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"urls\": [\"https://example.com\"]}'"
