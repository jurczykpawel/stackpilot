#!/bin/bash

# StackPilot - Stirling-PDF
# Your local, privacy-friendly PDF Swiss Army Knife.
# Merge, Split, Convert, OCR - all in your browser.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=1000  # frooodle/s-pdf:latest (~1GB with Java+LibreOffice)
#
# ⚠️  NOTE: This app requires at least 2GB RAM (2GB+ VPS)!
#     Stirling-PDF uses Java (Spring Boot) + LibreOffice for conversion.
#     On a 1GB VPS it may cause the server to hang.
#
# Optional environment variables:
#   DOMAIN - domain for Stirling-PDF

set -e

APP_NAME="stirling-pdf"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8087}

# Port binding: Cytrus needs 0.0.0.0, Cloudflare/Caddy/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

echo "--- 📄 Stirling-PDF Setup ---"

# Check available RAM - REQUIRED minimum 2GB!
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")

if [ "$TOTAL_RAM" -lt 1800 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ ERROR: Not enough RAM for Stirling-PDF!                    ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Your server: ${TOTAL_RAM}MB RAM                                        ║"
    echo "║  Required:    2048MB RAM (2GB+ VPS)                            ║"
    echo "║                                                                ║"
    echo "║  Stirling-PDF uses Java + LibreOffice (~600-800MB RAM).       ║"
    echo "║  On a 1GB VPS it hangs the server!                             ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  💡 ALTERNATIVE: Gotenberg                                     ║"
    echo "║     Lightweight API for document conversion (~150MB RAM)       ║"
    echo "║     Install: ./local/deploy.sh gotenberg                       ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# Set container memory limit based on available RAM
if [ "$TOTAL_RAM" -ge 3000 ]; then
    MEMORY_LIMIT="1536M"
    echo "✅ RAM: ${TOTAL_RAM}MB - container limit: 1.5GB"
else
    MEMORY_LIMIT="1024M"
    echo "✅ RAM: ${TOTAL_RAM}MB - container limit: 1GB"
fi
echo ""

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Caddy)"
else
    echo "⚠️  No domain - using localhost"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null

services:
  stirling-pdf:
    image: frooodle/s-pdf:latest
    restart: always
    ports:
      - "${BIND_ADDR}$PORT:8080"
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

# Health check - Stirling-PDF needs ~90-120s to start (Java + LibreOffice)
echo "⏳ Waiting for Stirling-PDF to start (~90s for Java)..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 120 || { echo "❌ Installation failed!"; exit 1; }
else
    # Fallback - wait up to 120s
    for i in $(seq 1 12); do
        sleep 10
        if curl -sf "http://localhost:$PORT" > /dev/null 2>&1 || curl -sf "http://localhost:$PORT/login" > /dev/null 2>&1; then
            echo "✅ Stirling-PDF is running (after $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 12 ]; then
            echo "❌ Container failed to start within 120s!"
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

# Caddy/HTTPS - configure reverse proxy if domain is set
if [ -n "$DOMAIN" ]; then
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ Stirling-PDF started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
