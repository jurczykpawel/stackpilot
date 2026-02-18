#!/bin/bash

# StackPilot - Coolify
# Open-source PaaS. Your private Heroku/Vercel with 280+ apps.
# https://coolify.io
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=2500  # coolify + postgres:15 + redis:7 + soketi + traefik
#
# ⚠️  REQUIRES: 8GB+ VPS (8GB RAM, 80GB disk, 2x CPU)
#     Coolify is a full PaaS - it manages ALL apps on the server.
#     Traefik takes over ports 80/443 (SSL, routing).
#     Do not install alongside other apps from stackpilot!
#
# Coolify installs to /data/coolify/ (NOT /opt/stacks/).
# Containers: coolify (Laravel), postgres:15, redis:7, soketi (WebSocket), traefik
# Ports: 8000 (UI), 80 (HTTP), 443 (HTTPS), 6001 (WebSocket)
#
# Optional environment variables:
#   ROOT_USERNAME     - admin login (skips registration screen)
#   ROOT_USER_EMAIL   - admin email
#   ROOT_USER_PASSWORD - admin password
#   AUTOUPDATE        - "false" to disable auto-updates (default: enabled)

set -e

APP_NAME="coolify"

echo "--- 🚀 Coolify Setup ---"
echo "Open-source PaaS: Your private Heroku/Vercel with 280+ apps."
echo ""

# =============================================================================
# 1. PRE-FLIGHT CHECKS
# =============================================================================

# --- RAM check ---
TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
TOTAL_RAM=${TOTAL_RAM:-0}

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 3500 ]; then
    echo "❌ Coolify requires at least 4GB RAM!"
    echo ""
    echo "   Your server: ${TOTAL_RAM}MB RAM"
    echo "   Required:    4096MB (minimum)"
    echo "   Recommended: 8192MB (8GB+ VPS)"
    echo ""
    echo "   Coolify is a full PaaS (4 platform containers + Traefik)."
    echo "   On smaller servers, use deploy.sh with individual apps."
    exit 1
fi

if [ "$TOTAL_RAM" -gt 0 ] && [ "$TOTAL_RAM" -lt 7500 ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  Coolify recommends 8GB RAM (8GB+ VPS)                  ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Your server: ${TOTAL_RAM}MB RAM                             ║"
    echo "║  Recommended: 8192MB RAM (8GB+ VPS)                          ║"
    echo "║                                                              ║"
    echo "║  Coolify will work, but little RAM will be left for apps.    ║"
    echo "║  The platform itself uses ~500-800MB.                        ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
fi

echo "✅ RAM: ${TOTAL_RAM}MB"

# --- Disk check ---
FREE_DISK=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
FREE_DISK=${FREE_DISK:-0}

if [ "$FREE_DISK" -gt 0 ] && [ "$FREE_DISK" -lt 20000 ]; then
    echo "❌ Coolify requires at least 20GB of free space!"
    echo ""
    echo "   Free:      ${FREE_DISK}MB (~$((FREE_DISK / 1024))GB)"
    echo "   Required:  20GB (minimum)"
    echo "   Recommended: 40GB+ (Docker images for apps take 500MB-3GB each)"
    exit 1
fi

if [ "$FREE_DISK" -gt 0 ] && [ "$FREE_DISK" -lt 35000 ]; then
    echo "⚠️  Disk: ${FREE_DISK}MB free (~$((FREE_DISK / 1024))GB) - might get tight"
else
    echo "✅ Disk: ${FREE_DISK}MB free (~$((FREE_DISK / 1024))GB)"
fi

# --- Port check ---
PORTS_BUSY=0
for CHECK_PORT in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":${CHECK_PORT} "; then
        echo "⚠️  Port $CHECK_PORT is in use!"
        PORTS_BUSY=1
    fi
done

if [ "$PORTS_BUSY" -eq 1 ]; then
    echo ""
    echo "   Coolify needs ports 80 (HTTP) and 443 (HTTPS)."
    echo "   Traefik (Coolify's reverse proxy) will take over these ports."
    echo "   Existing services on these ports may stop working!"
    echo ""
fi

# --- Port 8000 (Coolify UI) ---
source /opt/stackpilot/lib/port-utils.sh 2>/dev/null || true
COOLIFY_PORT=8000
if ss -tlnp 2>/dev/null | grep -q ":8000 "; then
    echo "⚠️  Port 8000 is in use! Looking for a free port for Coolify UI..."
    if type find_free_port &>/dev/null; then
        COOLIFY_PORT=$(find_free_port 8001)
    else
        # Fallback without lib
        COOLIFY_PORT=$(ss -tlnp 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | awk 'BEGIN{p=8001} p==$1{p++} END{print p}')
    fi
    echo "✅ Using port $COOLIFY_PORT for Coolify UI"
fi

# --- Existing stacks warning ---
EXISTING_STACKS=0
if [ -d /opt/stacks ]; then
    EXISTING_STACKS=$(ls -d /opt/stacks/*/docker-compose.yaml 2>/dev/null | wc -l || true)
fi
if [ "$EXISTING_STACKS" -gt 0 ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  Found $EXISTING_STACKS existing stacks in /opt/stacks/         ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Coolify takes over ports 80/443 via Traefik.                ║"
    echo "║  Apps installed via deploy.sh may stop working.              ║"
    echo "║                                                              ║"
    echo "║  Coolify works best on a fresh server.                       ║"
    echo "║  After installation, manage ALL apps through the panel.      ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
fi

# =============================================================================
# 2. COOLIFY INSTALLATION (official script)
# =============================================================================

echo "📥 Downloading and running the official Coolify installer..."
echo "   Source: https://cdn.coollabs.io/coolify/install.sh"
echo ""
echo "   The installer will:"
echo "   • Configure Docker (if needed)"
echo "   • Create /data/coolify/ (config, databases, SSH keys)"
echo "   • Download and start platform containers"
echo "   • Configure Traefik (reverse proxy)"
echo ""

# Pass environment variables to the official installer
# ROOT_USERNAME/ROOT_USER_EMAIL/ROOT_USER_PASSWORD - admin pre-configuration
# AUTOUPDATE - disable auto-updates
export ROOT_USERNAME="${ROOT_USERNAME:-}"
export ROOT_USER_EMAIL="${ROOT_USER_EMAIL:-}"
export ROOT_USER_PASSWORD="${ROOT_USER_PASSWORD:-}"
export AUTOUPDATE="${AUTOUPDATE:-}"

# Disable set -e during the official installer
# (has its own set -e, but some exit codes are buggy - exit 0 on error)
set +e
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
INSTALL_EXIT=$?
set -e

# If port 8000 was in use, switch to free port
if [ "$COOLIFY_PORT" != "8000" ] && [ -f /data/coolify/source/.env ]; then
    echo ""
    echo "🔧 Changing Coolify UI port: 8000 → $COOLIFY_PORT"
    sed -i "s/^APP_PORT=.*/APP_PORT=$COOLIFY_PORT/" /data/coolify/source/.env
    cd /data/coolify/source && docker compose up -d 2>/dev/null
    sleep 5
fi

if [ "$INSTALL_EXIT" -ne 0 ]; then
    echo ""
    echo "❌ Official Coolify installer failed (exit code: $INSTALL_EXIT)"
    echo ""
    echo "   Check the logs above. Common causes:"
    echo "   • No connection to CDN (cdn.coollabs.io)"
    echo "   • Docker could not start"
    echo "   • Missing root permissions"
    echo ""
    echo "   Try again - the installer is idempotent."
    echo "   Logs: cd /data/coolify/source && docker compose logs -f"
    exit 1
fi

# =============================================================================
# 3. HEALTH CHECK
# =============================================================================

# The official installer has its own health check (180s),
# so if we got here, Coolify should already be running.
# We do a quick verification just in case.

echo ""
echo "⏳ Verifying Coolify panel availability..."

COOLIFY_UP=0
for i in $(seq 1 6); do
    if curl -sf "http://localhost:$COOLIFY_PORT" > /dev/null 2>&1; then
        COOLIFY_UP=1
        break
    fi
    sleep 5
done

if [ "$COOLIFY_UP" -eq 0 ]; then
    echo "⚠️  Panel is still starting up. Check in a moment:"
    echo "   curl http://localhost:$COOLIFY_PORT"
    echo "   cd /data/coolify/source && docker compose logs -f"
    echo ""
fi

# =============================================================================
# 4. SUMMARY
# =============================================================================

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<server-IP>")

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ Coolify installed!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "🔗 Panel: http://${SERVER_IP}:${COOLIFY_PORT}"
echo ""

if [ -n "$ROOT_USERNAME" ] && [ -n "$ROOT_USER_PASSWORD" ]; then
    echo "🔑 Admin account: pre-configured ($ROOT_USERNAME)"
else
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  🔒 IMPORTANT: Open the panel NOW and create an admin account!║"
    echo "║     The first registered user = administrator.                ║"
    echo "║     Until you register, the panel is open to everyone!        ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
fi

echo ""
echo "📝 Next steps:"
echo "   1. Open http://${SERVER_IP}:${COOLIFY_PORT} → create admin account"
echo "   2. Add server (Coolify auto-detects localhost)"
echo "   3. Configure domain in Settings → General"
echo "   4. Deploy your first app: Resources → + New → Service"
echo ""
echo "🏗️  Coolify Architecture:"
echo "   • Panel UI:      port $COOLIFY_PORT"
echo "   • Traefik HTTP:  port 80  (reverse proxy for apps)"
echo "   • Traefik HTTPS: port 443 (automatic SSL Let's Encrypt)"
echo "   • Data:          /data/coolify/"
echo ""
echo "📋 Useful commands:"
echo "   cd /data/coolify/source && docker compose logs -f   # logs"
echo "   cd /data/coolify/source && docker compose restart    # restart"
echo ""
