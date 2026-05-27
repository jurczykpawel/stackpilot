#!/bin/bash

# StackPilot - Server-Side Google Tag Manager (sGTM)
# Self-hosted GTM server container for 1st-party data collection,
# server-side tagging, and improved tracking reliability.
# Requires a custom domain — sGTM only works with HTTPS on your own subdomain.
#
# IMAGE_SIZE_MB=300  # gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable
#
# Required environment variables (passed by deploy.sh):
#   CONTAINER_CONFIG — base64-encoded container config string from GTM UI
#                      (GTM → Admin → Container Settings → Container Config)
#   DOMAIN (optional) — custom domain; sGTM requires one to function properly

set -e

APP_NAME="sgtm"
STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
PORT=${PORT:-8084}

echo "--- 🏷️  Server-Side GTM Setup ---"
echo "Google Tag Manager running server-side for 1st-party data collection."
echo ""

if [ -z "$CONTAINER_CONFIG" ]; then
    echo "❌ Error: Missing CONTAINER_CONFIG!"
    echo ""
    echo "   Get it from: GTM → Admin → Container Settings → Container Config"
    echo "   It looks like: ZW52LCJodHRwczovL3d3dy5nb29nbGV0YWdtYW5hZ2..."
    echo ""
    echo "   Then run:"
    echo "   CONTAINER_CONFIG='your-config-string' ./local/deploy.sh sgtm \\"
    echo "     --ssh=vps --domain-type=cloudflare --domain=gtm.example.com"
    exit 1
fi

echo "✅ Container config: provided (${#CONTAINER_CONFIG} chars)"

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  sgtm:
    image: gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable
    restart: always
    ports:
      - "$PORT:8080"
    environment:
      - CONTAINER_CONFIG=$CONTAINER_CONFIG
    healthcheck:
      test: ["CMD", "node", "-e", "const http=require('http');http.request({host:'localhost',port:8080,path:'/healthz'},r=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>{process.exit(1)}).end()"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
    deploy:
      resources:
        limits:
          memory: 256M
EOF

sudo docker compose up -d

# Health check
_HC=/opt/stackpilot/lib/health-check.sh
if [ -f "$_HC" ]; then
    source "$_HC"
fi
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 60 || { echo "❌ Installation failed!"; exit 1; }
else
    echo "Checking if container started..."
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Container is running"
    else
        echo "❌ Container failed to start!"
        sudo docker compose logs --tail 20
        exit 1
    fi
fi

echo ""
echo "✅ Server-Side GTM installed successfully"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 sGTM endpoint: https://$DOMAIN"
    echo ""
    echo "👉 Next steps:"
    echo "   1. In GTM UI, set server container URL: https://$DOMAIN"
    echo "   2. Update your GA4 client-side tag → server_container_url"
    echo "   3. Test via GTM preview mode"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "⚠️  No domain configured — sGTM requires a custom domain to function"
    echo "   Redeploy with: --domain-type=cloudflare --domain=gtm.example.com"
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
