#!/bin/bash

# StackPilot - Vaultwarden
# Lightweight Bitwarden server written in Rust.
# Secure password management for your business.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=330  # vaultwarden/server:latest
#
# Optional environment variables:
#   DOMAIN - domain for Vaultwarden

set -e

APP_NAME="vaultwarden"
STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
source "${STACKPILOT_LIB:-/opt/stackpilot/lib}/stack-config.sh"
PORT=${PORT:-8088}

# Port binding: Cytrus needs 0.0.0.0, Cloudflare/Caddy/local → 127.0.0.1
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

echo "--- 🔐 Vaultwarden Setup ---"
echo "NOTE: Once installed, create your account immediately."
echo "Then, restart the container with SIGNUPS_ALLOWED=false to secure it."
echo ""

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Caddy)"
else
    echo "⚠️  No domain - using localhost"
fi

# Admin panel /admin: disabled by default; a re-install keeps the current token
# and changes or removes it only when asked to.
ADMIN_TOKEN=$(stack_value "$STACK_DIR/docker-compose.yaml" ADMIN_TOKEN || true)
# Compose reads "$name" as a variable, so every $ of an Argon2 hash is stored as $$
[[ "$ADMIN_TOKEN" == *'$$'* ]] || ADMIN_TOKEN="${ADMIN_TOKEN//\$/\$\$}"

new_admin_token() {
    local plain_token hashed_token
    plain_token=$(openssl rand -hex 32)

    if ! command -v argon2 &>/dev/null; then
        echo "📦 Installing argon2..."
        sudo apt-get install -y argon2 > /dev/null 2>&1 || true
    fi

    if command -v argon2 &>/dev/null; then
        hashed_token=$(echo -n "$plain_token" | argon2 "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4)
        ADMIN_TOKEN="${hashed_token//\$/\$\$}"
    else
        ADMIN_TOKEN="$plain_token"
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  SAVE THIS TOKEN — IT CANNOT BE RECOVERED!              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  $plain_token  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Use it to log in at /admin. Only the Argon2 hash is stored"
    echo "  in docker-compose — save the original yourself (e.g. in Vaultwarden)."
    echo ""
    read -p "  Press Enter when you have saved the token..." _
}

if [ -z "$YES" ] && [ -z "$YES_MODE" ]; then
    echo ""
    if [ -n "$ADMIN_TOKEN" ]; then
        read -p "🔐 Admin panel /admin is enabled. Keep the current token (Enter), set a new one (n) or disable the panel (d)? " ADMIN_ANSWER
        case "$ADMIN_ANSWER" in
            [nN]) new_admin_token ;;
            [dD]) ADMIN_TOKEN="" ;;
        esac
    else
        read -p "🔐 Enable admin panel /admin? (N/y): " ENABLE_ADMIN
        if [[ "$ENABLE_ADMIN" =~ ^[yY]$ ]]; then
            new_admin_token
        fi
    fi
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Set domain URL
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    DOMAIN_URL="https://$DOMAIN"
else
    DOMAIN_URL="http://localhost:$PORT"
fi

# Registration is closed by hand after creating the account; a re-install keeps that
SIGNUPS_ALLOWED=$(stack_value "$STACK_DIR/docker-compose.yaml" SIGNUPS_ALLOWED || echo true)

{
    cat <<COMPOSE
services:
  vaultwarden:
    image: vaultwarden/server:latest
    restart: always
    ports:
      - "${BIND_ADDR}${PORT}:80"
    environment:
      - DOMAIN=${DOMAIN_URL}
      - SIGNUPS_ALLOWED=${SIGNUPS_ALLOWED}
      - WEBSOCKET_ENABLED=true
COMPOSE
    cat <<'COMPOSE'
      # --- Admin panel ---
      # To enable manually:
      #   1. Generate token:     openssl rand -hex 32
      #   2. Hash with Argon2:   echo -n "YOUR_TOKEN" | argon2 "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4
      #   3. Uncomment and paste the hash below, writing every $ as $$ (if no argon2: apt install argon2)
      #   4. Restart:            docker compose up -d
      #   5. Log in with the original token (not the hash) at /admin
      #   6. When done, comment out ADMIN_TOKEN and restart
      #- ADMIN_TOKEN=$$argon2id$$v=19$$m=65540,t=3,p=4$$SALT$$HASH
COMPOSE
    [ -z "$ADMIN_TOKEN" ] || printf '      - ADMIN_TOKEN=%s\n' "$ADMIN_TOKEN"
    cat <<'COMPOSE'
    volumes:
      - ./data:/data
    deploy:
      resources:
        limits:
          memory: 128M
COMPOSE
} | sudo tee docker-compose.yaml > /dev/null

sudo docker compose up -d

# Health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 30 || { echo "❌ Installation failed!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Vaultwarden is running"
    else
        echo "❌ Container failed to start!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Caddy/HTTPS - configure reverse proxy if domain is set
if [ -n "$DOMAIN" ]; then
    if command -v sp-expose &> /dev/null; then
        sudo sp-expose "$DOMAIN" "$PORT"
    fi
fi

echo ""
echo "✅ Vaultwarden started!"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi
echo ""
if [ -n "$ADMIN_TOKEN" ]; then
    echo "🔐 Admin panel ENABLED at /admin (token in docker-compose)"
else
    echo "🔒 Admin panel DISABLED (default)."
    echo "   To enable: see $STACK_DIR/docker-compose.yaml (instructions in comments)"
fi
if [ "$SIGNUPS_ALLOWED" = true ]; then
    echo ""
    echo "📝 Next steps:"
    echo "   1. Create your account in the browser"
    echo "   2. Disable registration (command below!)"
    echo ""
    echo "🔒 IMPORTANT — disable registration after creating your account:"
    echo "   ssh ${SSH_ALIAS:-vps} 'cd $STACK_DIR && sed -i \"s/SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/\" docker-compose.yaml && docker compose up -d'"
fi
