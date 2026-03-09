#!/bin/bash

# StackPilot - Sellf
# Self-hosted digital products sales platform (Gumroad/EasyCart alternative)
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=500  # sellf (Next.js app ~500MB)
#
# Requirements:
#   - 1GB+ VPS (1GB RAM)
#   - Supabase: cloud account (free) OR self-hosted (deploy.sh supabase first)
#   - Stripe account (for payments)
#
# Supabase modes (set SUPABASE_MODE):
#   cloud  (default) - External Supabase cloud: provide SUPABASE_URL + keys
#   local            - Self-hosted Supabase on this server: reads from
#                      ~/.config/stackpilot/supabase/deploy-config.env
#                      (run: deploy.sh supabase first)
#
# Runtime modes (set RUNTIME):
#   pm2    (default) - Bun + PM2 process manager (lightweight, ~50MB RAM)
#   docker           - Docker container (isolated, reproducible, ~200MB RAM)
#                      Builds image locally from the downloaded tar.gz artifact.
#
# Environment variables:
#   RUNTIME                - pm2 (default) | docker
#   SUPABASE_MODE          - cloud (default) | local
#   SUPABASE_URL           - Supabase URL (cloud mode or override for local)
#   SUPABASE_ANON_KEY      - Supabase anon/publishable key
#   SUPABASE_SERVICE_KEY   - Supabase service_role key
#   STRIPE_PK              - Stripe Publishable Key (optional, set via UI)
#   STRIPE_SK              - Stripe Secret Key (optional, set via UI)
#   STRIPE_WEBHOOK_SECRET  - Stripe Webhook Secret (optional)
#   DOMAIN                 - Application domain

set -e

# shellcheck disable=SC2034  # APP_NAME is used by toolbox conventions / external scripts
APP_NAME="sellf"
GITHUB_REPO="jurczykpawel/sellf"

# =============================================================================
# MULTI-INSTANCE: instance name from domain
# =============================================================================
# Extract first part of domain as instance name
# shop.example.com → shop
#
# For multi-instance you must provide specific domains upfront.
#
if [ -n "$DOMAIN" ]; then
    INSTANCE_NAME="${DOMAIN%%.*}"
else
    INSTANCE_NAME=""
fi

# Set paths and names based on instance
# Install to /opt/stacks so backup works automatically
if [ -n "$INSTANCE_NAME" ]; then
    INSTALL_DIR="/opt/stacks/sellf-${INSTANCE_NAME}"
    PM2_NAME="sellf-${INSTANCE_NAME}"
else
    INSTALL_DIR="/opt/stacks/sellf"
    PM2_NAME="sellf"

    # Check if directory already exists (prevent overwrite without specific domain)
    if [ -d "$INSTALL_DIR/admin-panel" ] && [ -f "$INSTALL_DIR/admin-panel/.env.local" ]; then
        echo "Directory $INSTALL_DIR already exists!"
        echo ""
        echo "   Without a domain, only ONE instance is supported."
        echo "   For multiple instances use specific domains:"
        echo "   ./local/deploy.sh sellf --domain=shop.example.com"
        echo "   ./local/deploy.sh sellf --domain=test.example.com"
        echo ""
        echo "   Or remove the existing installation:"
        echo "   pm2 delete sellf && rm -rf $INSTALL_DIR"
        exit 1
    fi
fi

PORT=${PORT:-3333}
RUNTIME="${RUNTIME:-pm2}"

echo "--- 💰 Sellf Setup ---"
echo ""
if [ -n "$INSTANCE_NAME" ]; then
    echo "📦 Instance: $INSTANCE_NAME"
    echo "   Directory: $INSTALL_DIR"
    if [ "$RUNTIME" = "docker" ]; then
        echo "   Runtime: Docker"
    else
        echo "   PM2: $PM2_NAME"
    fi
    echo ""
fi

# =============================================================================
# 1. INSTALL RUNTIME DEPENDENCIES
# =============================================================================

if [ "$RUNTIME" = "docker" ]; then
    # Docker mode: only Docker is needed (already required by stackpilot)
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker is not installed. Install it first:"
        echo "   curl -fsSL https://get.docker.com | sh"
        exit 1
    fi
    echo "✅ Runtime: Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"
    echo ""
else
    # PM2 mode: install Bun + Node.js + PM2
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"

    if ! command -v bun &> /dev/null || ! command -v pm2 &> /dev/null; then
        echo "📦 Installing Bun + PM2..."
        if [ -f "/opt/stackpilot/system/bun-setup.sh" ]; then
            source /opt/stackpilot/system/bun-setup.sh
        else
            # Fallback - install directly
            command -v unzip &> /dev/null || apt-get install -y unzip -qq 2>/dev/null || true
            curl -fsSL https://bun.sh/install | bash
            export PATH="$HOME/.bun/bin:$PATH"
            bun install -g pm2
        fi
    fi

    # PM2 requires real Node.js for fork mode IPC (bun's child_process.fork is
    # not fully compatible with PM2's process management protocol).
    # Install Node.js LTS via NodeSource if not already present.
    # Also remove any bun->node symlink that may shadow the real node binary.
    if [ -L "/root/.bun/bin/node" ]; then
        rm -f /root/.bun/bin/node
    fi
    if ! /usr/bin/node --version &> /dev/null 2>&1; then
        echo "📦 Installing Node.js LTS (required by PM2)..."
        if command -v apt-get &> /dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - 2>/dev/null
            apt-get install -y nodejs 2>/dev/null || true
        elif command -v yum &> /dev/null; then
            curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - 2>/dev/null
            yum install -y nodejs 2>/dev/null || true
        fi
    fi

    # Add PATH to shell rc file (so pm2 works via SSH)
    add_path_to_rc() {
        local RC_FILE="$1"
        local PREPEND="${2:-false}"

        if [ "$PREPEND" = "true" ] && [ -f "$RC_FILE" ]; then
            {
                echo '# Bun & PM2 (added by stackpilot)'
                echo 'export PATH="$HOME/.bun/bin:$PATH"'
                echo ''
                cat "$RC_FILE"
            } > "${RC_FILE}.new"
            mv "${RC_FILE}.new" "$RC_FILE"
        else
            echo '' >> "$RC_FILE"
            echo '# Bun & PM2 (added by stackpilot)' >> "$RC_FILE"
            echo 'export PATH="$HOME/.bun/bin:$PATH"' >> "$RC_FILE"
        fi
    }

    if ! grep -q '\.bun/bin' ~/.bashrc 2>/dev/null && \
       ! grep -q '\.bun/bin' ~/.zshrc 2>/dev/null && \
       ! grep -q '\.bun/bin' ~/.profile 2>/dev/null; then
        case "$SHELL" in
            */zsh)
                add_path_to_rc ~/.zshrc false
                echo "✅ Added PATH to ~/.zshrc"
                ;;
            */bash)
                if [ -f ~/.bashrc ]; then
                    add_path_to_rc ~/.bashrc true
                    echo "✅ Added PATH to ~/.bashrc"
                else
                    add_path_to_rc ~/.profile false
                    echo "✅ Added PATH to ~/.profile"
                fi
                ;;
            *)
                add_path_to_rc ~/.profile false
                echo "✅ Added PATH to ~/.profile"
                ;;
        esac
    fi

    echo "✅ Bun: v$(bun --version)"
    echo "✅ PM2: v$(pm2 --version 2>/dev/null)"
    echo ""
fi

# =============================================================================
# 2. DOWNLOAD PRE-BUILT RELEASE
# =============================================================================

mkdir -p "$INSTALL_DIR/admin-panel"
cd "$INSTALL_DIR/admin-panel"

# Check if we already have files (update vs fresh install)
if [ -d ".next/standalone" ]; then
    echo "✅ Sellf already downloaded - using existing files"
else
    echo "📥 Downloading Sellf..."

    # Check if we have a local file (passed by deploy.sh)
    if [ -n "$BUILD_FILE" ] && [ -f "$BUILD_FILE" ]; then
        echo "   Using file: $BUILD_FILE"
        if ! tar -xzf "$BUILD_FILE"; then
            echo ""
            echo "❌ Failed to extract file"
            echo "   Make sure the file is a valid .tar.gz archive"
            exit 1
        fi
    else
        # Download from GitHub
        # Try /latest (requires a tagged "latest release" on GitHub)
        RELEASE_URL="https://github.com/$GITHUB_REPO/releases/latest/download/sellf-build.tar.gz"

        if ! curl -fsSL "$RELEASE_URL" 2>/dev/null | tar -xz 2>/dev/null; then
            # Fallback: find the newest release with sellf-build.tar.gz artifact
            echo "   /latest unavailable, looking for the newest release with build..."
            RELEASE_URL=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases" 2>/dev/null \
                | grep -m1 "browser_download_url.*sellf-build" | sed 's/.*: "\(.*\)".*/\1/')

            if [ -n "$RELEASE_URL" ]; then
                LATEST_TAG=$(echo "$RELEASE_URL" | sed 's|.*/download/\([^/]*\)/.*|\1|')
                echo "   Found: $LATEST_TAG"
                if ! curl -fsSL "$RELEASE_URL" | tar -xz; then
                    echo ""
                    echo "❌ Failed to download Sellf ($LATEST_TAG)"
                    exit 1
                fi
            else
                echo ""
                echo "❌ Failed to download Sellf from GitHub"
                echo ""
                echo "   Possible causes:"
                echo "   • No release with sellf-build.tar.gz artifact"
                echo "   • Repository is private"
                echo "   • No internet connection"
                echo ""
                echo "   Solution: Download the file manually and use the --build-file flag:"
                echo "   ./local/deploy.sh sellf --ssh=vps --build-file=~/Downloads/sellf-build.tar.gz"
                exit 1
            fi
        fi
    fi

    if [ ! -d ".next/standalone" ]; then
        echo ""
        echo "❌ Invalid archive structure"
        echo "   Archive should contain a .next/standalone folder"
        exit 1
    fi

    echo "✅ Sellf downloaded"
fi
echo ""

# =============================================================================
# 3. SUPABASE CONFIGURATION
# =============================================================================

ENV_FILE="$INSTALL_DIR/admin-panel/.env.local"
SUPABASE_MODE="${SUPABASE_MODE:-cloud}"

if [ -f "$ENV_FILE" ] && grep -q "SUPABASE_URL=" "$ENV_FILE"; then
    echo "✅ Supabase configuration already exists"
else
    # --- LOCAL MODE: read keys from self-hosted Supabase on this server ---
    if [ "$SUPABASE_MODE" = "local" ] && [ -z "$SUPABASE_URL" ]; then
        LOCAL_SUPABASE_CONFIG="$HOME/.config/stackpilot/supabase/deploy-config.env"
        if [ -f "$LOCAL_SUPABASE_CONFIG" ]; then
            echo "✅ Loading local Supabase config from $LOCAL_SUPABASE_CONFIG"
            source "$LOCAL_SUPABASE_CONFIG"
            # supabase/install.sh saves: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY
        else
            echo "❌ Local Supabase config not found: $LOCAL_SUPABASE_CONFIG"
            echo ""
            echo "   Deploy Supabase first:"
            echo "   ./local/deploy.sh supabase --ssh=vps --domain-type=local"
            echo ""
            echo "   Or use cloud mode (default):"
            echo "   ./local/deploy.sh sellf --ssh=vps --supabase=cloud"
            exit 1
        fi
    fi

    # --- VALIDATE: keys must be present (cloud: passed by deploy.sh, local: loaded above) ---
    if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_ANON_KEY" ] && [ -n "$SUPABASE_SERVICE_KEY" ]; then
        echo "✅ Configuring Supabase (mode: $SUPABASE_MODE)..."

        cat > "$ENV_FILE" <<ENVEOF
# Supabase ($SUPABASE_MODE mode)
SUPABASE_URL=$SUPABASE_URL
SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY=$SUPABASE_SERVICE_KEY

# Encryption key for integrations (Stripe UI wizard, GUS, Currency API)
# AES-256-GCM - DO NOT CHANGE! Losing the key = reset of integration config
APP_ENCRYPTION_KEY=$(openssl rand -base64 32)
ENVEOF
    else
        echo "❌ Missing Supabase configuration!"
        echo ""
        if [ "$SUPABASE_MODE" = "local" ]; then
            echo "   Local Supabase config found but keys are missing."
            echo "   Try redeploying Supabase: ./local/deploy.sh supabase --ssh=vps"
        else
            echo "   Run deploy.sh interactively or provide variables:"
            echo "   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY"
        fi
        exit 1
    fi
fi

# Make sure APP_ENCRYPTION_KEY exists (for older installations)
if ! grep -q "APP_ENCRYPTION_KEY=" "$ENV_FILE" 2>/dev/null; then
    echo "🔐 Generating encryption key..."
    cat >> "$ENV_FILE" <<ENVEOF

# Encryption key for integrations (Stripe UI wizard, GUS, Currency API)
# AES-256-GCM - DO NOT CHANGE! Losing the key = reset of integration config
APP_ENCRYPTION_KEY=$(openssl rand -base64 32)
ENVEOF
fi

# =============================================================================
# 4. STRIPE CONFIGURATION
# =============================================================================

if grep -q "STRIPE_PUBLISHABLE_KEY" "$ENV_FILE" 2>/dev/null; then
    echo "✅ Stripe configuration already exists"
elif [ -n "$STRIPE_PK" ] && [ -n "$STRIPE_SK" ]; then
    # Use keys passed by deploy.sh (collected locally in PHASE 1.5)
    echo "✅ Configuring Stripe..."
    cat >> "$ENV_FILE" <<ENVEOF

# Stripe Configuration
STRIPE_PUBLISHABLE_KEY=$STRIPE_PK
STRIPE_SECRET_KEY=$STRIPE_SK
STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET:-}
STRIPE_COLLECT_TERMS_OF_SERVICE=false
ENVEOF
else
    # No keys - add placeholders (will be configured in UI)
    echo "ℹ️  Stripe will be configured in the panel after installation"
    cat >> "$ENV_FILE" <<ENVEOF

# Stripe Configuration (configure via UI wizard in the panel)
STRIPE_PUBLISHABLE_KEY=
STRIPE_SECRET_KEY=
STRIPE_COLLECT_TERMS_OF_SERVICE=false
ENVEOF
fi

# =============================================================================
# 5. DOMAIN AND URL CONFIGURATION
# =============================================================================

# Domain and URL configuration
if grep -q "SITE_URL=https://" "$ENV_FILE" 2>/dev/null; then
    echo "URL configuration already exists"
else
    if [ -n "$DOMAIN" ]; then
        SITE_URL="https://$DOMAIN"
    elif [ -t 0 ]; then
        echo ""
        read -p "Application domain (e.g. app.example.com): " DOMAIN
        SITE_URL="https://$DOMAIN"
    else
        SITE_URL="https://localhost:$PORT"
        DOMAIN="localhost"
    fi

    # HSTS is handled by Caddy, disable in app to avoid double HSTS headers
    DISABLE_HSTS="true"

    cat >> "$ENV_FILE" <<ENVEOF

# Site URLs (runtime)
SITE_URL=$SITE_URL
MAIN_DOMAIN=$DOMAIN

# Production
NODE_ENV=production
PORT=$PORT
# :: listens on IPv4 and IPv6
HOSTNAME=::
NEXT_TELEMETRY_DISABLED=1

# HSTS (disable for reverse proxy with SSL termination)
DISABLE_HSTS=$DISABLE_HSTS
ENVEOF
fi

# =============================================================================
# 5.1. TURNSTILE CONFIGURATION (if keys provided)
# =============================================================================

if [ -n "$CLOUDFLARE_TURNSTILE_SITE_KEY" ] && [ -n "$CLOUDFLARE_TURNSTILE_SECRET_KEY" ]; then
    if ! grep -q "CLOUDFLARE_TURNSTILE_SITE_KEY" "$ENV_FILE" 2>/dev/null; then
        cat >> "$ENV_FILE" <<ENVEOF

# Cloudflare Turnstile (CAPTCHA)
CLOUDFLARE_TURNSTILE_SITE_KEY=$CLOUDFLARE_TURNSTILE_SITE_KEY
CLOUDFLARE_TURNSTILE_SECRET_KEY=$CLOUDFLARE_TURNSTILE_SECRET_KEY
# Alias for Supabase Auth
TURNSTILE_SECRET_KEY=$CLOUDFLARE_TURNSTILE_SECRET_KEY
ENVEOF
        echo "✅ Turnstile configured"
    fi
fi

chmod 600 "$ENV_FILE"
echo "✅ Configuration saved to $ENV_FILE"
echo ""

# =============================================================================
# 6. START APPLICATION (PM2 or Docker)
# =============================================================================

if [ "$RUNTIME" = "docker" ]; then

    # -------------------------------------------------------------------------
    # DOCKER MODE
    # -------------------------------------------------------------------------
    # Build a Docker image from the downloaded tar.gz artifact (no registry
    # needed — everything is built locally on the server).
    # The Dockerfile is bundled inside the tar.gz as admin-panel/Dockerfile.

    echo "📋 Preparing Docker build..."

    DOCKER_IMAGE="sellf-${INSTANCE_NAME:-default}"
    DOCKER_NAME="sellf-${INSTANCE_NAME:-default}"
    STACK_DIR="$INSTALL_DIR"

    # Write .env file for docker-compose (docker-compose reads .env, not .env.local)
    cp "$ENV_FILE" "$STACK_DIR/.env"

    # Generate docker-compose.yml
    cat > "$STACK_DIR/docker-compose.yml" <<DCEOF
services:
  sellf:
    image: ${DOCKER_IMAGE}:latest
    container_name: ${DOCKER_NAME}
    restart: unless-stopped
    network_mode: host
    env_file: .env
    environment:
      - PORT=${PORT}
      - HOSTNAME=::
      - NODE_ENV=production
    deploy:
      resources:
        limits:
          memory: 512M
DCEOF

    # Build a minimal Docker image that runs the pre-built Next.js standalone server.
    # We do NOT rebuild the app from source (slow, needs bun install + build).
    # Instead we copy the already-built standalone/ output and run server.js with Node.
    echo "🔨 Building Docker image ${DOCKER_IMAGE}:latest..."

    STANDALONE_DIR_DOCKER="$INSTALL_DIR/admin-panel/.next/standalone/admin-panel"
    if [ ! -f "$STANDALONE_DIR_DOCKER/server.js" ]; then
        # Fallback: standalone without subdir (older releases)
        STANDALONE_DIR_DOCKER="$INSTALL_DIR/admin-panel/.next/standalone"
    fi
    if [ ! -f "$STANDALONE_DIR_DOCKER/server.js" ]; then
        echo "❌ server.js not found — archive may be invalid"
        echo "   Searched: $INSTALL_DIR/admin-panel/.next/standalone/admin-panel/"
        exit 1
    fi

    # Copy static assets into standalone (same as PM2 mode)
    cp -r "$INSTALL_DIR/admin-panel/.next/static" "$STANDALONE_DIR_DOCKER/.next/" 2>/dev/null || true
    cp -r "$INSTALL_DIR/admin-panel/public" "$STANDALONE_DIR_DOCKER/" 2>/dev/null || true
    cp "$ENV_FILE" "$STANDALONE_DIR_DOCKER/.env.local"

    # Write a minimal Dockerfile next to the standalone server
    cat > "$STANDALONE_DIR_DOCKER/Dockerfile.stackpilot" <<'INNERDF'
FROM node:lts-alpine
WORKDIR /app
COPY . .
ENV NODE_ENV=production
EXPOSE 3333
CMD ["node", "server.js"]
INNERDF

    if ! docker build \
        --tag "${DOCKER_IMAGE}:latest" \
        --file "$STANDALONE_DIR_DOCKER/Dockerfile.stackpilot" \
        "$STANDALONE_DIR_DOCKER"; then
        echo "❌ Docker build failed"
        exit 1
    fi

    # Cleanup temp Dockerfile
    rm -f "$STANDALONE_DIR_DOCKER/Dockerfile.stackpilot"

    echo "✅ Docker image built"

    # Stop PM2 process if it was previously running in PM2 mode
    if command -v pm2 &> /dev/null && pm2 list 2>/dev/null | grep -q "$PM2_NAME"; then
        echo "🛑 Stopping existing PM2 process ($PM2_NAME)..."
        pm2 delete "$PM2_NAME" 2>/dev/null || true
        pm2 save 2>/dev/null || true
    fi

    # Stop old container if running
    echo "🚀 Starting Sellf (Docker)..."
    cd "$STACK_DIR"
    docker compose down 2>/dev/null || true
    docker compose up -d

    # Wait and check
    sleep 5
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
        echo "✅ Application responding on port $PORT (HTTP $HTTP_CODE)"
    else
        echo "⚠️  Application may still be starting... (HTTP $HTTP_CODE)"
        echo "   Logs: docker logs ${DOCKER_NAME}"
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "✅ Sellf installed! (Docker mode)"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "📋 Useful commands:"
    echo "   docker ps                           - container status"
    echo "   docker logs ${DOCKER_NAME}          - logs"
    echo "   cd $STACK_DIR && docker compose restart  - restart"
    echo ""

else

    # -------------------------------------------------------------------------
    # PM2 MODE (default)
    # -------------------------------------------------------------------------

    echo "📋 Configuring standalone server..."

    STANDALONE_DIR="$INSTALL_DIR/admin-panel/.next/standalone/admin-panel"

    if [ -d "$STANDALONE_DIR" ]; then
        cp "$ENV_FILE" "$STANDALONE_DIR/.env.local"
        cp -r "$INSTALL_DIR/admin-panel/.next/static" "$STANDALONE_DIR/.next/" 2>/dev/null || true
        cp -r "$INSTALL_DIR/admin-panel/public" "$STANDALONE_DIR/" 2>/dev/null || true
        echo "✅ Standalone configured (env + static files)"
    else
        echo "⚠️  No standalone folder - using standard start"
    fi

    echo "🚀 Starting Sellf..."

    # Stop Docker container if it was previously running in Docker mode
    DOCKER_NAME_PM2="sellf-${INSTANCE_NAME:-default}"
    if docker ps -q --filter "name=${DOCKER_NAME_PM2}" 2>/dev/null | grep -q .; then
        echo "🛑 Stopping existing Docker container (${DOCKER_NAME_PM2})..."
        docker compose -f "$INSTALL_DIR/docker-compose.yml" down 2>/dev/null || true
    fi

    pm2 delete "$PM2_NAME" 2>/dev/null || true

    if [ -f "$STANDALONE_DIR/server.js" ]; then
        cd "$STANDALONE_DIR"

        # Prefer /usr/bin/node (system Node.js) to avoid bun->node symlink issues
        if [ -x "/usr/bin/node" ]; then
            NODE_BIN="/usr/bin/node"
        else
            NODE_BIN="$(command -v node)"
        fi

        # Generate PM2 ecosystem file with env vars baked in so they persist
        # across daemon restarts and server reboots (unlike shell `source`).
        ECOSYSTEM_FILE="$STANDALONE_DIR/ecosystem.config.js"

        ENV_JS=""
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            val="${val%\"}"; val="${val#\"}"
            val="${val%\'}"; val="${val#\'}"
            val="${val//\\/\\\\}"; val="${val//\'/\\\'}"
            ENV_JS="${ENV_JS}    '${key}': '${val}',\n"
        done < .env.local

        cat > "$ECOSYSTEM_FILE" <<ECOEOF
module.exports = {
  apps: [{
    name: '$PM2_NAME',
    script: 'server.js',
    interpreter: '$NODE_BIN',
    cwd: '$STANDALONE_DIR',
    env: {
$(printf '%b' "$ENV_JS")
      PORT: '${PORT:-3333}',
      HOSTNAME: '::',
      NODE_ENV: 'production',
    }
  }]
}
ECOEOF

        pm2 start "$ECOSYSTEM_FILE"
    else
        cd "$INSTALL_DIR/admin-panel"
        pm2 start server.js --name "$PM2_NAME" --interpreter bun
    fi

    pm2 save

    sleep 3

    if pm2 list | grep -q "$PM2_NAME.*online"; then
        echo "✅ Sellf is running!"
    else
        echo "❌ Problem starting. Logs:"
        pm2 logs "$PM2_NAME" --lines 20
        exit 1
    fi

    sleep 2
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
        echo "✅ Application responding on port $PORT (HTTP $HTTP_CODE)"
    else
        echo "⚠️  Application may still be starting... (HTTP $HTTP_CODE)"
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "✅ Sellf installed!"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "📋 Useful commands:"
    echo "   pm2 status              - application status"
    echo "   pm2 logs $PM2_NAME - logs"
    echo "   pm2 restart $PM2_NAME - restart"
    echo ""

fi
