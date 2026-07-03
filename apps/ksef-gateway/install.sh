#!/bin/bash

# StackPilot - KSeF Gateway
# Universal REST API gateway for Poland's national e-invoicing system (KSeF),
# wrapping the official CIRFMF KSeF SDK. Send & receive invoices, get PDFs with
# verification QR codes — over a simple HTTP API. Open source, self-hosted.
# https://github.com/jurczykpawel/ksef-gateway
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=900  # ksef-api (.NET 9) + ksef-pdf (Node), extracted; no DB, no Redis
#
# Stack: ksef-api (ASP.NET Core, port 8080) → ksef-pdf (Node/pdfmake, internal only).
# Pre-built images are pulled from GHCR — nothing is built on the server.
#
# What the installer sets ITSELF (zero questions): GATEWAY_API_KEY (caller auth) and
# PDF_SERVICE_SECRET (guards the internal PDF service). What you add afterwards to talk
# to KSeF: your KSEF_TOKEN + KSEF_NIP (from the KSeF portal) — pass them as env at
# install time, or drop them into the .env and restart. The gateway boots healthy
# without them; /ksef/status just reports "unauthenticated" until you add the token.
#
# Environment variables:
#   IMAGE_TAG   - GHCR image tag to deploy (default: latest; pin e.g. v0.2.0 in prod)
#   IMAGE_REPO  - registry base (default: ghcr.io/jurczykpawel; images are
#                 <base>/ksef-gateway-api and <base>/ksef-gateway-pdf)
#   DOMAIN      - public domain (passed by deploy.sh)
#   KSEF_TOKEN  - your KSeF authorisation token (optional at install; add later)
#   KSEF_NIP    - the NIP that token belongs to (optional at install; add later)
#   KSEF_ENV    - TEST | DEMO | PROD (default: TEST — switch to PROD for real invoices)
#   GITHUB_PAT  - only needed while the GHCR images are private: a token with
#                 read:packages. Set GITHUB_USER too. Once the images are public,
#                 leave both unset and the pull is anonymous.
#   GITHUB_USER - GitHub username for the GHCR login (used only with GITHUB_PAT)

set -e

APP_NAME="ksef-gateway"
STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
PORT=${PORT:-8080}
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/jurczykpawel}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
API_IMAGE="${IMAGE_REPO}/ksef-gateway-api:${IMAGE_TAG}"

echo "--- 🧾 KSeF Gateway Setup ---"
echo "Self-hosted REST gateway for Poland's national e-invoicing (KSeF)."
echo ""

# Port binding: Cytrus needs 0.0.0.0, Cloudflare/Caddy/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

# KSeF environment: TEST by default (safe sandbox). Set KSEF_ENV=PROD for real invoices.
KSEF_ENV="${KSEF_ENV:-TEST}"

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    APP_URL="https://$DOMAIN"
    echo "✅ Domain: $DOMAIN"
else
    APP_URL="http://localhost:$PORT"
    echo "ℹ️  No domain — reachable on http://localhost:$PORT (use an SSH tunnel)"
fi
echo "ℹ️  KSeF environment: $KSEF_ENV"
echo ""

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

ENV_FILE="$STACK_DIR/.env"

# =============================================================================
# 1. CONFIGURATION (.env) — generate the secrets the installer can set itself
# =============================================================================
# GATEWAY_API_KEY is the only caller-facing auth (every request except /health
# needs it as X-Api-Key). Rotating it would lock out existing clients, so on a
# re-deploy we KEEP the existing .env.

if [ -f "$ENV_FILE" ] && grep -q '^GATEWAY_API_KEY=' "$ENV_FILE"; then
    echo "✅ Existing configuration preserved ($ENV_FILE)"
    GATEWAY_API_KEY=$(grep '^GATEWAY_API_KEY=' "$ENV_FILE" | cut -d= -f2-)
else
    echo "🔐 Generating secrets..."
    GATEWAY_API_KEY=$(openssl rand -hex 32)
    PDF_SERVICE_SECRET=$(openssl rand -hex 32)

    cat <<EOF | sudo tee "$ENV_FILE" > /dev/null
# ─── Caller authentication (REQUIRED) ───
# Every request except GET /health must send this as the header:  X-Api-Key: <value>
# The gateway has no other caller-facing auth, so it fails closed without it.
GATEWAY_API_KEY=$GATEWAY_API_KEY

# ─── Internal PDF service secret (auto-generated) ───
# The gateway calls the companion ksef-pdf service over the private compose network
# and signs the call with this. Keep it identical on both services.
PDF_SERVICE_SECRET=$PDF_SERVICE_SECRET
PDF_SERVICE_URL=http://ksef-pdf:3000

# ─── KSeF authentication — ADD THESE to actually talk to KSeF ───
# Get a token from the KSeF portal for your NIP (TEST or PROD), paste it here,
# then: cd $STACK_DIR && sudo docker compose up -d
# Alternatively use a certificate — see the README "Certificate-Based Auth".
KSEF_TOKEN=${KSEF_TOKEN:-}
KSEF_NIP=${KSEF_NIP:-}
KSEF_ENV=$KSEF_ENV

# ─── Multi-NIP (optional) — needs a GATEWAY_LICENSE. A single NIP is always free. ───
GATEWAY_LICENSE=
EOF
    sudo chmod 600 "$ENV_FILE"
    echo "✅ Secrets generated → $ENV_FILE"
fi
echo ""

# =============================================================================
# 2. COMPOSE — ksef-api (public port) → ksef-pdf (internal only), images from GHCR
# =============================================================================

cat <<EOF | sudo tee "$STACK_DIR/docker-compose.yaml" > /dev/null
services:
  ksef-api:
    image: "${IMAGE_REPO}/ksef-gateway-api:${IMAGE_TAG}"
    restart: always
    env_file: .env
    environment:
      KSEF_ENV: \${KSEF_ENV:-TEST}
      PDF_SERVICE_URL: http://ksef-pdf:3000
    ports:
      - "${BIND_ADDR}${PORT}:8080"
    depends_on:
      ksef-pdf:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/health"]
      interval: 15s
      timeout: 5s
      start_period: 20s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 400M

  ksef-pdf:
    image: "${IMAGE_REPO}/ksef-gateway-pdf:${IMAGE_TAG}"
    restart: always
    environment:
      PDF_SERVICE_SECRET: \${PDF_SERVICE_SECRET:-}
    expose:
      - "3000"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:3000/health"]
      interval: 15s
      timeout: 5s
      start_period: 15s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 320M
EOF
echo "✅ docker-compose.yaml written (api: $API_IMAGE)"
echo ""

# =============================================================================
# 3. PULL & START
# =============================================================================
# The GHCR images are pulled anonymously. While they are still private, pass a
# GITHUB_PAT (+ GITHUB_USER) with read:packages and we log in first.

if [ -n "${GITHUB_PAT:-}" ]; then
    echo "🔑 Logging in to GHCR (private images)..."
    echo "$GITHUB_PAT" | sudo docker login ghcr.io -u "${GITHUB_USER:-jurczykpawel}" --password-stdin
fi

echo "📥 Pulling images from GHCR..."
sudo docker compose pull

echo "🚀 Starting KSeF Gateway..."
sudo docker compose up -d

# =============================================================================
# 4. HEALTH CHECK
# =============================================================================

echo "⏳ Waiting for the gateway..."
HEALTHY=false
for i in $(seq 1 24); do
    sleep 5
    if curl -fsS "http://localhost:$PORT/health" > /dev/null 2>&1; then
        echo "✅ KSeF Gateway is healthy (after $((i*5))s)"
        HEALTHY=true
        break
    fi
done

if [ "$HEALTHY" != "true" ]; then
    echo "❌ KSeF Gateway did not become healthy in 120s."
    echo "   Logs: cd $STACK_DIR && sudo docker compose logs ksef-api --tail 50"
    sudo docker compose logs ksef-api --tail 30 2>/dev/null || true
    exit 1
fi

# =============================================================================
# 5. NEXT STEPS
# =============================================================================

HAS_TOKEN=false
if grep -q '^KSEF_TOKEN=.\+' "$ENV_FILE" 2>/dev/null; then HAS_TOKEN=true; fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ KSeF Gateway installed!"
echo "════════════════════════════════════════════════════════════════"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 API:  $APP_URL"
    echo "📖 Docs: $APP_URL/scalar/v1   (send header  X-Api-Key: <your key>)"
else
    echo "🔗 SSH tunnel: ssh -L $PORT:localhost:$PORT <server>  →  http://localhost:$PORT"
fi
echo "🔑 API key (X-Api-Key header):"
echo "     $GATEWAY_API_KEY"
echo "   (also in $ENV_FILE — chmod 600)"
echo ""
if [ "$HAS_TOKEN" = "true" ]; then
    echo "🧾 KSeF token configured for env: $KSEF_ENV"
    echo "   Check auth:  curl $APP_URL/ksef/status -H \"X-Api-Key: $GATEWAY_API_KEY\""
else
    echo "🧾 NEXT: connect KSeF (the gateway is up but not yet authenticated):"
    echo "   1. Get a KSeF token for your NIP (env: $KSEF_ENV) from the KSeF portal."
    echo "   2. Put KSEF_TOKEN + KSEF_NIP into  $ENV_FILE"
    echo "   3. cd $STACK_DIR && sudo docker compose up -d"
    echo "   Verify:  curl $APP_URL/ksef/status -H \"X-Api-Key: <key>\""
fi
echo ""
echo "📋 Useful commands:"
echo "   cd $STACK_DIR && sudo docker compose ps            - status"
echo "   cd $STACK_DIR && sudo docker compose logs -f ksef-api - logs"
echo "   ./local/deploy.sh ksef-gateway --update            - update to the latest image"
