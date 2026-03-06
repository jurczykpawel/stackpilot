#!/bin/bash

# StackPilot - Supabase Self-Hosted
# Open-source Firebase alternative: PostgreSQL, Auth, Storage, Realtime, Functions, Studio.
# https://supabase.com/docs/guides/self-hosting/docker
#
# IMAGE_SIZE_MB=4000  # ~10 containers: studio, kong, auth, rest, realtime, storage,
#                       imgproxy, meta, analytics, db, vector, supavisor
#
# ⚠️  REQUIRES: Minimum 2GB RAM
#     Recommended: 3GB+ RAM
#     Supabase runs ~10 Docker service containers.
#
# Optional environment variables (passed by deploy.sh or set manually):
#   PORT              - Kong API + Studio port (default: 8000)
#   POSTGRES_PASSWORD - PostgreSQL password (auto-generated)
#   JWT_SECRET        - JWT secret (auto-generated)
#   DASHBOARD_PASSWORD - Dashboard password (auto-generated)
#   SITE_URL          - Site URL for Auth redirects (default: SUPABASE_PUBLIC_URL)

set -e

APP_NAME="supabase"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8000}

echo "--- 🔥 Supabase Self-Hosted Setup ---"
echo "Open-source Firebase alternative: PostgreSQL, Auth, Storage, Realtime, Functions."
echo ""

# =============================================================================
# 1. PRE-FLIGHT CHECKS
# =============================================================================

# RAM check
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo 0)

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 1800 ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ Not enough RAM! Supabase requires a minimum of 2GB RAM.  ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    printf "║  Your server:  %-4s MB RAM                                   ║\n" "$TOTAL_RAM"
    echo "║  Required:     2048 MB (minimum)                              ║"
    echo "║  Recommended:  3072 MB                                        ║"
    echo "║                                                                ║"
    echo "║  Supabase runs ~10 Docker containers.                         ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 2800 ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  Supabase recommends 3GB RAM                             ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    printf "║  Your server:  %-4s MB RAM                                   ║\n" "$TOTAL_RAM"
    echo "║  2GB works, but may leave little RAM for other apps.          ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
fi

# Disk check
FREE_DISK=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
if [ "$FREE_DISK" -gt 0 ] && [ "$FREE_DISK" -lt 3000 ]; then
    echo "❌ Not enough disk space! Required: 3GB, available: ${FREE_DISK}MB (~$((FREE_DISK / 1024))GB)"
    exit 1
fi

echo "✅ RAM: ${TOTAL_RAM}MB | Disk: ${FREE_DISK}MB free"

# Port check for PostgreSQL pooler
POOLER_HOST_PORT=5432
if ss -tlnp 2>/dev/null | grep -q ":5432 " || netstat -tlnp 2>/dev/null | grep -q ":5432 "; then
    POOLER_HOST_PORT=5433
    echo "⚠️  Port 5432 in use — PostgreSQL pooler will be available on host port 5433"
fi
echo ""

# =============================================================================
# 2. GENERATE SECRETS
# Uses the same approach as the official generate-keys.sh
# =============================================================================

echo "🔐 Generating secrets..."

# JWT helper (pure openssl - no python/node needed)
base64_url_encode() {
    openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

gen_jwt() {
    local secret="$1"
    local role="$2"
    local header='{"alg":"HS256","typ":"JWT"}'
    local iat exp payload header_b64 payload_b64 signed sig
    iat=$(date +%s)
    exp=$((iat + 5 * 3600 * 24 * 365))
    payload="{\"role\":\"${role}\",\"iss\":\"supabase\",\"iat\":${iat},\"exp\":${exp}}"
    header_b64=$(printf '%s' "$header" | base64_url_encode)
    payload_b64=$(printf '%s' "$payload" | base64_url_encode)
    signed="${header_b64}.${payload_b64}"
    sig=$(printf '%s' "$signed" | openssl dgst -binary -sha256 -hmac "$secret" | base64_url_encode)
    printf '%s' "${signed}.${sig}"
}

# Preserve credentials from existing install to avoid password mismatch with existing DB volumes.
# The Supabase postgres image blocks ALTER USER supabase_admin via SQL (reserved role),
# so if volumes exist from a previous run, they must use the same POSTGRES_PASSWORD.
if [ -f "$STACK_DIR/.env" ]; then
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(sudo grep '^POSTGRES_PASSWORD=' "$STACK_DIR/.env" 2>/dev/null | cut -d= -f2)}"
    JWT_SECRET="${JWT_SECRET:-$(sudo grep '^JWT_SECRET=' "$STACK_DIR/.env" 2>/dev/null | cut -d= -f2)}"
    DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-$(sudo grep '^DASHBOARD_PASSWORD=' "$STACK_DIR/.env" 2>/dev/null | cut -d= -f2)}"
    echo "   ℹ️  Existing credentials preserved (reinstall)"
fi

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
JWT_SECRET="${JWT_SECRET:-$(openssl rand -base64 30)}"
SECRET_KEY_BASE=$(openssl rand -base64 48)
VAULT_ENC_KEY=$(openssl rand -hex 16)
PG_META_CRYPTO_KEY=$(openssl rand -base64 24)
LOGFLARE_PUBLIC_TOKEN=$(openssl rand -base64 24)
LOGFLARE_PRIVATE_TOKEN=$(openssl rand -base64 24)
S3_ACCESS_KEY=$(openssl rand -hex 16)
S3_SECRET_KEY=$(openssl rand -hex 32)
MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)
POOLER_TENANT_ID=$(openssl rand -hex 8)
DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-$(openssl rand -hex 16)}"

echo "   Generating JWT keys..."
ANON_KEY=$(gen_jwt "$JWT_SECRET" "anon")
SERVICE_ROLE_KEY=$(gen_jwt "$JWT_SECRET" "service_role")

echo "✅ Secrets generated"

# =============================================================================
# 3. DOWNLOAD OFFICIAL DOCKER SETUP FROM GITHUB
# =============================================================================

echo ""
echo "📥 Downloading official Supabase Docker setup..."
sudo mkdir -p "$STACK_DIR"

if [ -f "$STACK_DIR/docker-compose.yml" ]; then
    echo "✅ Docker setup already exists (skipping download)"
else
    if ! command -v git &>/dev/null; then
        echo "❌ git not found! Install with: apt-get install -y git"
        exit 1
    fi

    TMP_DIR=$(mktemp -d)
    echo "   Cloning Supabase repository (docker/ directory only)..."

    git clone \
        --filter=blob:none \
        --no-checkout \
        --depth 1 \
        --quiet \
        https://github.com/supabase/supabase.git "$TMP_DIR"

    cd "$TMP_DIR"
    git sparse-checkout init --cone 2>/dev/null || git sparse-checkout init
    git sparse-checkout set docker
    git checkout --quiet HEAD

    sudo cp -r docker/. "$STACK_DIR/"
    cd /
    rm -rf "$TMP_DIR"

    echo "✅ Docker setup downloaded from GitHub"
fi

cd "$STACK_DIR"

# =============================================================================
# 4. CONFIGURE .env
# =============================================================================

echo ""
echo "⚙️  Configuring .env..."

sudo cp .env.example .env

# URL configuration
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    SUPABASE_PUBLIC_URL="https://$DOMAIN"
else
    SUPABASE_PUBLIC_URL="http://localhost:$PORT"
fi
SITE_URL="${SITE_URL:-$SUPABASE_PUBLIC_URL}"

# Apply all settings
sudo sed -i \
    -e "s|^POSTGRES_PASSWORD=.*$|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" \
    -e "s|^JWT_SECRET=.*$|JWT_SECRET=${JWT_SECRET}|" \
    -e "s|^ANON_KEY=.*$|ANON_KEY=${ANON_KEY}|" \
    -e "s|^SERVICE_ROLE_KEY=.*$|SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}|" \
    -e "s|^SECRET_KEY_BASE=.*$|SECRET_KEY_BASE=${SECRET_KEY_BASE}|" \
    -e "s|^VAULT_ENC_KEY=.*$|VAULT_ENC_KEY=${VAULT_ENC_KEY}|" \
    -e "s|^PG_META_CRYPTO_KEY=.*$|PG_META_CRYPTO_KEY=${PG_META_CRYPTO_KEY}|" \
    -e "s|^LOGFLARE_PUBLIC_ACCESS_TOKEN=.*$|LOGFLARE_PUBLIC_ACCESS_TOKEN=${LOGFLARE_PUBLIC_TOKEN}|" \
    -e "s|^LOGFLARE_PRIVATE_ACCESS_TOKEN=.*$|LOGFLARE_PRIVATE_ACCESS_TOKEN=${LOGFLARE_PRIVATE_TOKEN}|" \
    -e "s|^S3_PROTOCOL_ACCESS_KEY_ID=.*$|S3_PROTOCOL_ACCESS_KEY_ID=${S3_ACCESS_KEY}|" \
    -e "s|^S3_PROTOCOL_ACCESS_KEY_SECRET=.*$|S3_PROTOCOL_ACCESS_KEY_SECRET=${S3_SECRET_KEY}|" \
    -e "s|^MINIO_ROOT_PASSWORD=.*$|MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}|" \
    -e "s|^DASHBOARD_PASSWORD=.*$|DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}|" \
    -e "s|^SUPABASE_PUBLIC_URL=.*$|SUPABASE_PUBLIC_URL=${SUPABASE_PUBLIC_URL}|" \
    -e "s|^API_EXTERNAL_URL=.*$|API_EXTERNAL_URL=${SUPABASE_PUBLIC_URL}|" \
    -e "s|^SITE_URL=.*$|SITE_URL=${SITE_URL}|" \
    -e "s|^POOLER_TENANT_ID=.*$|POOLER_TENANT_ID=${POOLER_TENANT_ID}|" \
    -e "s|^KONG_HTTP_PORT=.*$|KONG_HTTP_PORT=${PORT}|" \
    -e "s|^KONG_HTTPS_PORT=.*$|KONG_HTTPS_PORT=$((PORT + 443))|" \
    .env

# Patch pooler host port in docker-compose.yml if 5432 is taken on host.
# POSTGRES_PORT stays 5432 for internal Docker network; only the host binding changes.
if [ "$POOLER_HOST_PORT" != "5432" ]; then
    sudo sed -i "s|- \${POSTGRES_PORT}:5432|- ${POOLER_HOST_PORT}:5432|" docker-compose.yml
fi

sudo chmod 600 .env
echo "✅ Configuration ready"

# =============================================================================
# 5. START SUPABASE
# =============================================================================

echo ""
echo "🚀 Pulling Docker images and starting Supabase..."
echo "   (First run: 5-15 minutes, downloading ~3-4GB of images)"
echo ""

sudo docker compose pull

# Start db + vector first — analytics has a race condition on fresh DB init.
# The DB health check passes before init scripts finish, causing analytics to time out.
echo "   Starting database (initialization may take up to 5 min)..."
sudo docker compose up -d db vector

# Wait for DB init scripts to finish.
# The postgres role is created by migrate.sh during container init — it does NOT exist before
# migrate.sh runs (supabase_admin is in the image base, but postgres is created later).
# We connect via 127.0.0.1 (trust auth) as supabase_admin to avoid chicken-and-egg with peer auth.
DB_INIT_DONE=0
for i in $(seq 1 60); do
    if sudo docker exec supabase-db psql -U supabase_admin -h 127.0.0.1 -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='postgres'" 2>/dev/null | grep -q 1; then
        DB_INIT_DONE=1
        break
    fi
    printf "."
    sleep 5
done
echo ""

if [ "$DB_INIT_DONE" -ne 1 ]; then
    echo "⚠️  Database initialization is taking longer than expected — continuing"
fi

echo "   Starting all services..."
sudo docker compose up -d --wait --wait-timeout 300 || true

# =============================================================================
# 6. HEALTH CHECK
# =============================================================================

echo ""
echo "⏳ Waiting for API to come up (max 2.5 min)..."

SUPABASE_UP=0
for i in $(seq 1 30); do
    if curl -sf "http://localhost:$PORT/rest/v1/" \
        -H "apikey: $ANON_KEY" \
        -H "Authorization: Bearer $ANON_KEY" > /dev/null 2>&1; then
        SUPABASE_UP=1
        break
    fi
    printf "."
    sleep 5
done
echo ""

if [ "$SUPABASE_UP" -eq 1 ]; then
    echo "✅ API is up!"
else
    echo "⏳ API is still starting. Container status:"
    sudo docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null \
        || sudo docker compose ps
    echo ""
    echo "   Check logs: cd $STACK_DIR && sudo docker compose logs -f"
fi

# HTTPS via Caddy (for real domains only)
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ] && [[ "$DOMAIN" != *"pending"* ]] && [[ "$DOMAIN" != *"PENDING"* ]]; then
    echo "--- Configuring HTTPS via Caddy ---"
    if command -v sp-expose &>/dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    else
        echo "⚠️  'sp-expose' not found. Configure reverse proxy manually."
    fi
fi

# =============================================================================
# 7. SAVE CONFIGURATION
# =============================================================================

CONFIG_DIR="$HOME/.config/stackpilot/supabase"
CONFIG_FILE="$CONFIG_DIR/deploy-config.env"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<CONF
# Supabase Self-Hosted - Configuration
# Generated: $(date)

SUPABASE_URL=$SUPABASE_PUBLIC_URL
SUPABASE_ANON_KEY=$ANON_KEY
SUPABASE_SERVICE_KEY=$SERVICE_ROLE_KEY
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
JWT_SECRET=$JWT_SECRET
DASHBOARD_USERNAME=supabase
DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD
CONF

chmod 600 "$CONFIG_FILE"

# =============================================================================
# 8. SUMMARY
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "✅ Supabase installed successfully!"
echo "════════════════════════════════════════════════════════════════════"
echo ""

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Studio + API:  https://$DOMAIN"
else
    echo "🔗 Studio + API:  http://localhost:$PORT"
    echo ""
    echo "   SSH tunnel (from your machine):"
    echo "   ssh -L $PORT:localhost:$PORT <server>"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "🔑 CONFIGURATION — SAVE THESE CREDENTIALS IN A SAFE PLACE!"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Supabase URL:          $SUPABASE_PUBLIC_URL"
echo "  Anon Key (public):     $ANON_KEY"
echo "  Service Key (secret):  $SERVICE_ROLE_KEY"
echo ""
echo "  Dashboard login:       supabase"
echo "  Dashboard password:    $DASHBOARD_PASSWORD"
echo ""
echo "  PostgreSQL password:   $POSTGRES_PASSWORD"
echo ""
echo "  Configuration saved:   $CONFIG_FILE"
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  ⚠️  IMPORTANT: Configure SMTP before going to production!    ║"
echo "║     Edit: $STACK_DIR/.env → SMTP section                ║"
echo "║     Default: Inbucket (fake SMTP, for testing only).          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "📋 Management:"
echo "   cd $STACK_DIR"
echo "   sudo docker compose ps            # container status"
echo "   sudo docker compose logs -f       # all service logs"
echo "   sudo docker compose logs -f db    # PostgreSQL logs"
echo "   sudo docker compose restart       # restart"
echo "   sudo docker compose down          # stop"
echo ""
