#!/bin/bash

# StackPilot - PostStack
# Self-hosted multi-channel social media management: publishing & scheduling,
# inbox auto-replies, drip sequences, and CRM (Facebook, Instagram, YouTube,
# Telegram, Gmail). Source-available alternative to ManyChat / Buffer / Hootsuite.
# https://github.com/jurczykpawel/poststack
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=2700  # web + worker (Bun, node_modules-heavy) + postgres + nginx, extracted
# DB_BUNDLED=true    # bundled PostgreSQL in docker-compose — no external DB needed
#
# Stack: nginx → web (Hono/Bun) + worker (graphile-worker) + postgres.
# Pre-built images are pulled from GHCR (public) — nothing is built on the server.
#
# What the installer sets ITSELF (zero questions): POSTGRES_PASSWORD, ENCRYPTION_KEY,
# JWT_SECRET, CRON_SECRET, ALTCHA_HMAC_KEY, APP_URL (from DOMAIN), NODE_ENV, TRUSTED_PROXY.
# What you connect later in the UI (Settings): Meta (FB/IG), Google/YouTube/Gmail,
# license key (PRO), media storage. The app runs without them.
#
# Environment variables:
#   IMAGE_TAG  - GHCR image tag to deploy (default: latest; pin e.g. v0.8.3 in prod)
#   IMAGE_REPO - registry path (default: ghcr.io/jurczykpawel/poststack; forks override)
#   DOMAIN     - public domain (passed by deploy.sh)
#
# NOTE: Meta OAuth + webhooks require a public HTTPS endpoint — deploy with
#       --domain-type=cloudflare (or caddy). A plain Cytrus/HTTP deploy boots fine
#       but Meta channels won't connect until the app is reachable over HTTPS.

set -e

APP_NAME="poststack"
STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
PORT=${PORT:-3000}
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/jurczykpawel/poststack}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "--- 📣 PostStack Setup ---"
echo "Self-hosted social media publishing, inbox automation & CRM."
echo ""

# Port binding: Cytrus needs 0.0.0.0, Cloudflare/Caddy/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

# Behind Cloudflare the real client IP arrives in CF-Connecting-IP (it passes
# through Caddy + the bundled nginx untouched). Otherwise trust the bundled
# proxy's X-Real-IP / rightmost X-Forwarded-For hop.
if [ "${DOMAIN_TYPE:-}" = "cloudflare" ]; then
    TRUSTED_PROXY="cloudflare"
else
    TRUSTED_PROXY="proxy"
fi

# Public URL — drives OAuth redirects, the displayed webhook URL, and the
# same-origin guard on dashboard POSTs.
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    APP_URL="https://$DOMAIN"
    echo "✅ Domain: $DOMAIN"
else
    APP_URL="http://localhost:$PORT"
    echo "⚠️  No domain — booting on http://localhost:$PORT (Meta needs HTTPS)"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

ENV_FILE="$STACK_DIR/.env"

# =============================================================================
# 1. CONFIGURATION (.env) — generate secrets the installer can set itself
# =============================================================================
# ENCRYPTION_KEY must stay stable for the life of the instance (rotating it makes
# stored OAuth tokens undecryptable). So on a re-deploy we KEEP the existing .env.

if [ -f "$ENV_FILE" ] && grep -q '^ENCRYPTION_KEY=' "$ENV_FILE"; then
    echo "✅ Existing configuration preserved ($ENV_FILE)"
else
    echo "🔐 Generating secrets..."
    POSTGRES_PASSWORD=$(openssl rand -hex 16)

    cat <<EOF | sudo tee "$ENV_FILE" > /dev/null
# ─── Bundled PostgreSQL (in-network; do not point at an external DB here) ───
POSTGRES_USER=poststack
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=poststack

# ─── Auto-generated secrets — KEEP STABLE (rotating breaks stored data) ───
# AES-256-GCM key for stored OAuth tokens & secrets. NEVER change after channels connect.
ENCRYPTION_KEY=$(openssl rand -base64 32)
# JWT signing secret for session cookies.
JWT_SECRET=$(openssl rand -hex 32)
# Shared secret protecting the cron HTTP endpoints.
CRON_SECRET=$(openssl rand -hex 32)
# Proof-of-work CAPTCHA key for login/register (bot/brute-force defence).
ALTCHA_HMAC_KEY=$(openssl rand -hex 32)

# ─── App ───
APP_URL=$APP_URL
NODE_ENV=production
TRUSTED_PROXY=$TRUSTED_PROXY

# ─── Connect later in the UI → Settings (the app runs without these) ───
# Meta (Facebook & Instagram): OAuth + webhooks
# META_APP_ID=
# META_APP_SECRET=
# META_WEBHOOK_VERIFY_TOKEN=
# Google / YouTube / Gmail
# GOOGLE_CLIENT_ID=
# GOOGLE_CLIENT_SECRET=
# License (PRO features, from Sellf)
# LICENSE_KEY=
EOF
    sudo chmod 600 "$ENV_FILE"
    echo "✅ Secrets generated → $ENV_FILE"
fi
echo ""

# =============================================================================
# 2. REVERSE PROXY (nginx.conf) — SSE-aware, proxies to the web service
# =============================================================================

cat <<'EOF' | sudo tee "$STACK_DIR/nginx.conf" > /dev/null
server {
    listen 80;
    server_name _;

    client_max_body_size 10M;

    # Server-Sent Events stream. Buffering MUST be off so signals flush to the
    # browser immediately on the long-lived connection.
    location = /events/stream {
        proxy_pass http://web:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding off;
        proxy_read_timeout 3600s;
    }

    location / {
        proxy_pass http://web:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Accept-Encoding "";
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 60s;
    }
}
EOF
echo "✅ nginx.conf written"

# =============================================================================
# 3. COMPOSE — nginx → web + worker + bundled postgres (images from GHCR)
# =============================================================================
# DATABASE_URL is derived here from POSTGRES_* and points at the in-network
# postgres service (it overrides any value in .env). web listens on 3000, which
# is what nginx.conf proxies to.

cat <<EOF | sudo tee "$STACK_DIR/docker-compose.yaml" > /dev/null
services:
  nginx:
    image: nginx:alpine
    restart: always
    ports:
      - "${BIND_ADDR}${PORT}:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      web:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 64M

  web:
    image: "${IMAGE_REPO}:${IMAGE_TAG}"
    restart: always
    env_file: .env
    environment:
      DATABASE_URL: "postgresql://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@postgres:5432/\${POSTGRES_DB}"
      TRUSTED_PROXY: \${TRUSTED_PROXY:-proxy}
      REGISTRATION_ENABLED: \${REGISTRATION_ENABLED:-false}
      PORT: "3000"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      # Cold start runs migrations before serving — give it room before probing.
      start_period: 60s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 512M

  worker:
    image: "${IMAGE_REPO}-worker:${IMAGE_TAG}"
    restart: always
    env_file: .env
    environment:
      DATABASE_URL: "postgresql://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@postgres:5432/\${POSTGRES_DB}"
    depends_on:
      postgres:
        condition: service_healthy
      # web migrates the schema in its entrypoint; gate the worker on web being
      # healthy so it never pulls a job against a not-yet-migrated DB.
      web:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "sh", "/app/docker/worker-healthcheck.sh"]
      interval: 15s
      timeout: 5s
      start_period: 40s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 512M

  postgres:
    image: postgres:16-alpine
    restart: always
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER}"]
      interval: 5s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 256M

volumes:
  postgres_data:
EOF
echo "✅ docker-compose.yaml written (image: ${IMAGE_REPO}:${IMAGE_TAG})"
echo ""

# =============================================================================
# 4. PULL & START
# =============================================================================

echo "📥 Pulling images from GHCR..."
sudo docker compose pull

echo "🚀 Starting PostStack..."
sudo docker compose up -d

# =============================================================================
# 5. HEALTH CHECK (cold start migrates the DB — allow up to ~2 min)
# =============================================================================

echo "⏳ Waiting for the stack (migrations run on first boot)..."
HEALTHY=false
for i in $(seq 1 24); do
    sleep 5
    if curl -fsS "http://localhost:$PORT/api/health" > /dev/null 2>&1; then
        echo "✅ PostStack is healthy (after $((i*5))s)"
        HEALTHY=true
        break
    fi
done

if [ "$HEALTHY" != "true" ]; then
    echo "❌ PostStack did not become healthy in 120s."
    echo "   Logs: cd $STACK_DIR && sudo docker compose logs web --tail 50"
    sudo docker compose logs web --tail 30 2>/dev/null || true
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ PostStack installed!"
echo "════════════════════════════════════════════════════════════════"
echo ""
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 App: $APP_URL"
else
    echo "🔗 SSH tunnel: ssh -L $PORT:localhost:$PORT <server>  →  http://localhost:$PORT"
fi
echo "🔑 Secrets: $ENV_FILE  (auto-generated; keep ENCRYPTION_KEY stable)"
echo ""
echo "📋 Next steps:"
echo "   1. Open $APP_URL/register and create the FIRST account (= owner)."
echo "      Self-registration then stays closed (REGISTRATION_ENABLED=false)."
echo "   2. Connect Meta (Facebook/Instagram) in Settings:"
echo "      add META_APP_ID / META_APP_SECRET / META_WEBHOOK_VERIFY_TOKEN,"
echo "      then set the webhook URL to $APP_URL/api/webhooks/meta in the Meta App Dashboard."
echo "   3. Optional: Google/YouTube/Gmail, media storage, and a PRO license key."
echo ""
echo "📋 Useful commands:"
echo "   cd $STACK_DIR && sudo docker compose ps         - status"
echo "   cd $STACK_DIR && sudo docker compose logs -f web - logs"
echo "   ./local/deploy.sh poststack --update             - update to the latest image"
