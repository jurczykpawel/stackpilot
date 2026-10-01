#!/bin/bash

# StackPilot - Sellf Update
# Updates Sellf to the latest version
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/deploy.sh sellf --ssh=vps --update
#   ./local/deploy.sh sellf --ssh=vps --update --build-file=~/Downloads/sellf-build.tar.gz
#   ./local/deploy.sh sellf --ssh=vps --update --restart (restart without updating)
#
# Environment variables:
#   BUILD_FILE - path to local tar.gz file (instead of downloading from GitHub)
#   SELLF_RELEASE_LIB - path to apps/sellf/release-verify.sh (set by deploy.sh)
#
# A downloaded release is installed only if its signed manifest verifies, the
# archive matches the manifest checksum, and it is not older than the installed
# version (see apps/sellf/release-verify.sh). A --build-file archive is the
# operator's own build: only its entries are checked.
#
# Flags:
#   --restart - only restart the application (e.g. after changing .env), without downloading a new version
#
# Note: Database updates are handled by deploy.sh (Supabase API)

set -e

GITHUB_REPO="jurczykpawel/sellf"
RESTART_ONLY=false

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --restart)
            RESTART_ONLY=true
            shift
            ;;
    esac
done

# =============================================================================
# AUTO-DETECT INSTALLATION DIRECTORY
# =============================================================================
# New location: /opt/stacks/sellf* (backup-friendly)
# Old location: /root/sellf* (for compatibility)

find_sellf_dir() {
    local NAME="$1"
    # Check new location
    if [ -d "/opt/stacks/sellf-${NAME}" ]; then
        echo "/opt/stacks/sellf-${NAME}"
    elif [ -d "/root/sellf-${NAME}" ]; then
        echo "/root/sellf-${NAME}"
    elif [ -d "/opt/stacks/sellf" ]; then
        echo "/opt/stacks/sellf"
    elif [ -d "/root/sellf" ]; then
        echo "/root/sellf"
    fi
}

if [ -n "$INSTANCE" ]; then
    INSTALL_DIR=$(find_sellf_dir "$INSTANCE")
    PM2_NAME="sellf-${INSTANCE}"
elif ls -d /opt/stacks/sellf-* &>/dev/null 2>&1; then
    INSTALL_DIR=$(ls -d /opt/stacks/sellf-* 2>/dev/null | head -1)
    PM2_NAME="sellf-${INSTALL_DIR##*-}"
elif ls -d /root/sellf-* &>/dev/null 2>&1; then
    INSTALL_DIR=$(ls -d /root/sellf-* 2>/dev/null | head -1)
    PM2_NAME="sellf-${INSTALL_DIR##*-}"
elif [ -d "/opt/stacks/sellf" ]; then
    INSTALL_DIR="/opt/stacks/sellf"
    PM2_NAME="$PM2_NAME"
else
    INSTALL_DIR="/root/sellf"
    PM2_NAME="$PM2_NAME"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

UPDATE_I18N_LIB="$(dirname "${BASH_SOURCE[0]}")/../../lib/i18n.sh"
if [ -f "$UPDATE_I18N_LIB" ]; then
    source "$UPDATE_I18N_LIB"
fi

echo ""
if [ "$RESTART_ONLY" = true ]; then
    echo -e "${BLUE}🔄 Sellf Restart${NC}"
else
    echo -e "${BLUE}🔄 Sellf Update${NC}"
fi
echo ""

# =============================================================================
# 1. CHECK IF SELLF IS INSTALLED
# =============================================================================

if [ ! -d "$INSTALL_DIR/admin-panel" ]; then
    echo -e "${RED}❌ Sellf is not installed${NC}"
    echo "   Use deploy.sh for the first installation."
    exit 1
fi

ENV_FILE="$INSTALL_DIR/admin-panel/.env.local"
STANDALONE_DIR="$INSTALL_DIR/admin-panel/.next/standalone/admin-panel"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Missing .env.local file${NC}"
    exit 1
fi

echo "✅ Sellf found in $INSTALL_DIR"

# Get current version (if available)
CURRENT_VERSION="unknown"
if [ -f "$INSTALL_DIR/admin-panel/version.txt" ]; then
    CURRENT_VERSION=$(cat "$INSTALL_DIR/admin-panel/version.txt")
fi
echo "   Current version: $CURRENT_VERSION"

# =============================================================================
# 1.5. DOCKER INSTALLS: separate path, never PM2
# =============================================================================
# Detected by an existing docker-compose.yml (written by install.sh's Docker
# mode) or by RUNTIME=docker passed from deploy.sh (new instance, no compose
# file yet). Everything below this block is the PM2/tarball path and is
# never reached for a Docker install.

RUNTIME_DETECTED="pm2"
if [ -f "$INSTALL_DIR/docker-compose.yml" ] || [ "${RUNTIME:-}" = "docker" ]; then
    RUNTIME_DETECTED="docker"
fi

if [ "$RUNTIME_DETECTED" = "docker" ]; then
    # ----- SELLF DOCKER UPDATE START -----
    SELLF_RELEASE_LIB="${SELLF_RELEASE_LIB:-$(dirname "${BASH_SOURCE[0]}")/release-verify.sh}"
    if [ ! -f "$SELLF_RELEASE_LIB" ]; then
        echo -e "${RED}❌ Release verification helpers not found: $SELLF_RELEASE_LIB${NC}"
        echo "   Run the update through ./local/deploy.sh sellf --update"
        exit 1
    fi
    source "$SELLF_RELEASE_LIB"

    if [ "$RESTART_ONLY" = true ]; then
        echo ""
        echo "🔄 Restarting Sellf (Docker)..."
        # Fill in any secret a newer Sellf release now requires but this
        # install predates (see sellf_ensure_required_secrets). A bare
        # `docker compose restart` does not recreate the container, so this
        # only guarantees .env.local itself is complete for the next real
        # update/recreate — not that the running container picks it up now.
        sellf_ensure_required_secrets "$ENV_FILE"
        cp "$ENV_FILE" "$INSTALL_DIR/.env"
        cd "$INSTALL_DIR"
        docker compose restart
        echo ""
        echo -e "${GREEN}✅ Sellf restarted!${NC}"
        exit 0
    fi

    # Reuse the container name already recorded in the compose file (written by
    # install.sh's Docker mode); fall back to the install.sh naming convention
    # for an instance whose compose file does not exist yet.
    DOCKER_NAME=$(grep -m1 '^\s*container_name:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null | awk '{print $2}')
    DOCKER_NAME="${DOCKER_NAME:-sellf-${INSTANCE:-default}}"

    echo ""
    echo "🔏 Verifying signed image manifest..."
    if ! sellf_docker_deploy "$GITHUB_REPO" "$INSTALL_DIR" "$INSTALL_DIR/admin-panel" "$DOCKER_NAME" "$CURRENT_VERSION"; then
        echo -e "${RED}❌ Docker image verification failed — nothing was changed${NC}"
        exit 1
    fi
    echo "   Signature and digest OK ($SELLF_RELEASE_VERSION)"
    echo "   Image: $SELLF_IMAGE_REF"

    if [ "$CURRENT_VERSION" = "$SELLF_RELEASE_VERSION" ] && [ "$CURRENT_VERSION" != "unknown" ]; then
        echo -e "${YELLOW}⚠️  You already have the latest version ($CURRENT_VERSION)${NC}"
        # Only prompt when interactive — see the PM2 path below for why.
        if [ -t 0 ] && [ "${YES_MODE:-}" != "true" ]; then
            read -r -p "Continue anyway? [y/N]: " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[YyTt]$ ]]; then
                echo "Cancelled."
                exit 0
            fi
        else
            echo "   (non-interactive — re-applying the same version)"
        fi
    fi

    echo "$SELLF_RELEASE_VERSION" > "$INSTALL_DIR/admin-panel/version.txt"

    # Fill in any secret/flag this (or a newer) release requires that the
    # instance does not have yet — same helper the PM2 path below uses, so a
    # release that adds a new required secret cannot boot-loop a Docker
    # install that never got a chance to generate it.
    echo ""
    echo "🔐 Checking required secrets..."
    sellf_ensure_required_secrets "$ENV_FILE"

    # Refresh docker-compose's .env from .env.local in case it changed since
    # install (docker-compose reads .env, not .env.local).
    cp "$ENV_FILE" "$INSTALL_DIR/.env"

    echo ""
    echo "🚀 Starting Sellf (Docker)..."
    cd "$INSTALL_DIR"
    docker compose up -d --force-recreate

    sleep 3
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}✅ Sellf updated! (Docker mode)${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "   Previous version: $CURRENT_VERSION"
    echo "   New version: $SELLF_RELEASE_VERSION"
    echo ""
    echo "📋 Useful commands:"
    echo "   docker ps                                  - container status"
    echo "   docker logs ${DOCKER_NAME}                 - logs"
    echo "   cd $INSTALL_DIR && docker compose restart  - restart"
    echo ""

    exit 0
    # ----- SELLF DOCKER UPDATE END -----
fi

# ----- SELLF SYSTEM PATH START -----
SELLF_RELEASE_LIB="${SELLF_RELEASE_LIB:-$(dirname "${BASH_SOURCE[0]}")/release-verify.sh}"
if [ ! -f "$SELLF_RELEASE_LIB" ]; then
    echo "❌ Release verification helpers not found: $SELLF_RELEASE_LIB"
    exit 1
fi
source "$SELLF_RELEASE_LIB"
sellf_ensure_system_path
# ----- SELLF SYSTEM PATH END -----

# =============================================================================
# 2. DOWNLOAD NEW VERSION (skip in restart mode)
# =============================================================================

if [ "$RESTART_ONLY" = false ]; then
    echo ""

    # Backup old configuration
    cp "$ENV_FILE" "$INSTALL_DIR/.env.local.backup"
    echo "   .env.local backup created"

    # Extraction dir + a separate private dir for the downloaded release assets
    TEMP_DIR=$(mktemp -d)
    RELEASE_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR" "$RELEASE_DIR"' EXIT

    cd "$TEMP_DIR"

    # Check if we have a local file
    if [ -n "$BUILD_FILE" ] && [ -f "$BUILD_FILE" ]; then
        # A local build is the operator's own artifact: it has no release
        # signature, so only the archive entries are checked.
        echo "📦 Using local file: $BUILD_FILE"
        echo "   (local build — no release signature, checking archive entries only)"
        if ! sellf_validate_archive "$BUILD_FILE" || ! tar -xzf "$BUILD_FILE"; then
            echo -e "${RED}❌ Failed to extract file${NC}"
            exit 1
        fi
    else
        echo "📥 Downloading from GitHub..."
        if ! RELEASE_BASE_URL=$(sellf_release_base_url "$GITHUB_REPO") \
            || ! sellf_download_release "$RELEASE_DIR" "$RELEASE_BASE_URL"; then
            echo -e "${RED}❌ Failed to download new version${NC}"
            echo ""
            echo "If the repo is private, use --build-file:"
            echo "   ./local/deploy.sh sellf --ssh=vps --update --build-file=~/Downloads/sellf-build.tar.gz"
            exit 1
        fi

        echo "🔏 Verifying release..."
        if ! sellf_verify_release "$RELEASE_DIR"; then
            echo -e "${RED}❌ Release verification failed — nothing was changed${NC}"
            exit 1
        fi
        echo "   Signature, checksum and archive entries OK ($SELLF_RELEASE_VERSION)"

        # Newer or same (re-deploy) → continue; older → refuse.
        if ! sellf_check_update_version "$CURRENT_VERSION" "$SELLF_RELEASE_VERSION"; then
            exit 1
        fi

        if ! tar -xzf "$RELEASE_DIR/sellf-build.tar.gz"; then
            echo -e "${RED}❌ Failed to extract new version${NC}"
            exit 1
        fi
    fi

    if [ ! -d ".next/standalone" ]; then
        echo -e "${RED}❌ Invalid archive structure${NC}"
        exit 1
    fi

    # Check new version (signed manifest for releases, version.txt for local builds)
    NEW_VERSION="${SELLF_RELEASE_VERSION:-unknown}"
    if [ "$NEW_VERSION" = "unknown" ]; then
        if [ -f "version.txt" ]; then
            NEW_VERSION=$(cat version.txt)
        elif [ -n "${BUILD_FILE:-}" ]; then
            printf '%b\n' "$MSG_UPDATE_LOCAL_VERSION_MISSING"
        fi
    fi
    echo "   New version: $NEW_VERSION"

    if [ "$CURRENT_VERSION" = "$NEW_VERSION" ] && [ "$CURRENT_VERSION" != "unknown" ]; then
        echo -e "${YELLOW}⚠️  You already have the latest version ($CURRENT_VERSION)${NC}"
        # Only prompt when interactive. Under --yes / non-interactive (e.g. a
        # scripted re-deploy to re-run migrations), continue without blocking on
        # stdin — a bare `read` would hit EOF and `set -e` would abort the update.
        if [ -t 0 ] && [ "${YES_MODE:-}" != "true" ]; then
            read -r -p "Continue anyway? [y/N]: " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[YyTt]$ ]]; then
                echo "Cancelled."
                exit 0
            fi
        else
            echo "   (non-interactive — re-applying the same version)"
        fi
    fi
else
    echo ""
    echo "📋 Restart mode - skipped downloading new version"
fi

# =============================================================================
# 3. STOP APPLICATION
# =============================================================================

echo ""
echo "⏹️  Stopping Sellf..."

export PATH="$HOME/.bun/bin:$PATH"
pm2 stop $PM2_NAME 2>/dev/null || true

# =============================================================================
# 4. REPLACE FILES (skip in restart mode)
# =============================================================================

if [ "$RESTART_ONLY" = false ]; then
    echo ""
    echo "📦 Updating files..."

    # Remove old files (keep .env.local backup)
    rm -rf "$INSTALL_DIR/admin-panel/.next"
    rm -rf "$INSTALL_DIR/admin-panel/public"

    # Copy new files
    cp -r "$TEMP_DIR/.next" "$INSTALL_DIR/admin-panel/"
    cp -r "$TEMP_DIR/public" "$INSTALL_DIR/admin-panel/" 2>/dev/null || true
    cp "$TEMP_DIR/version.txt" "$INSTALL_DIR/admin-panel/" 2>/dev/null || true

    # Ship migration files so the DB step can apply NEW migrations. Without this
    # the server keeps the install-time set and new migrations are silently
    # skipped. The migration runner reads admin-panel/supabase/migrations.
    cp -r "$TEMP_DIR/supabase" "$INSTALL_DIR/admin-panel/" 2>/dev/null || true

    # Restore .env.local
    cp "$INSTALL_DIR/.env.local.backup" "$ENV_FILE"

    echo -e "${GREEN}✅ Files updated${NC}"
else
    echo ""
    echo "📋 Restart mode - skipped file update"
fi

# Ensure every secret/flag production startup requires exists (idempotent,
# never overwrites — see apps/sellf/release-verify.sh). Shared with the
# Docker update branch above and with install.sh, so a release that adds a
# new required secret only needs a change in one place.
if [ -f "$ENV_FILE" ]; then
    echo "🔐 Checking required secrets..."
    sellf_ensure_required_secrets "$ENV_FILE"
fi

if [ -f "$ENV_FILE" ] && ! grep -q "^SELLF_PM2_MAX_MEMORY=" "$ENV_FILE"; then
    printf "\nSELLF_PM2_MAX_MEMORY=512M\n" >> "$ENV_FILE"
    echo "   ⚙️  set SELLF_PM2_MAX_MEMORY=512M (PM2 kills+restarts if RSS exceeds this; raise to 1G on prod)"
fi

if [ -f "$ENV_FILE" ] && ! grep -q "^SELLF_NODE_MAX_OLD_SPACE=" "$ENV_FILE"; then
    printf "\nSELLF_NODE_MAX_OLD_SPACE=400\n" >> "$ENV_FILE"
    echo "   ⚙️  set SELLF_NODE_MAX_OLD_SPACE=400 (Node.js V8 heap limit in MB; set to ~80% of PM2 limit)"
fi

# Copy to standalone (always, both in update and restart)
STANDALONE_DIR="$INSTALL_DIR/admin-panel/.next/standalone/admin-panel"
if [ -d "$STANDALONE_DIR" ]; then
    echo "   Updating configuration in standalone..."
    cp "$ENV_FILE" "$STANDALONE_DIR/.env.local"
    if [ "$RESTART_ONLY" = false ]; then
        cp -r "$INSTALL_DIR/admin-panel/.next/static" "$STANDALONE_DIR/.next/" 2>/dev/null || true
        cp -r "$INSTALL_DIR/admin-panel/public" "$STANDALONE_DIR/" 2>/dev/null || true
    fi
fi

# Migrations are run by deploy.sh via Supabase API (not here)

# =============================================================================
# 5. START APPLICATION
# =============================================================================

echo ""
echo "🚀 Starting Sellf..."

cd "$STANDALONE_DIR"

# Load variables and start
# Clear system HOSTNAME (it's the machine name, not the listen address)
# Without this ${HOSTNAME:-::} never falls back to :: because the system always sets HOSTNAME
unset HOSTNAME
set -a
source .env.local
set +a
export PORT="${PORT:-3333}"
# :: listens on IPv4 and IPv6; firewall (iptables) restricts external direct access
export HOSTNAME="${HOSTNAME:-::}"

pm2 delete $PM2_NAME 2>/dev/null || true
# IMPORTANT: use --interpreter node, NOT "node server.js" in quotes
pm2 start server.js --name $PM2_NAME --interpreter node \
  --max-memory-restart "${SELLF_PM2_MAX_MEMORY:-512M}" \
  --node-args="--max-old-space-size=${SELLF_NODE_MAX_OLD_SPACE:-400}"
pm2 save

# Wait and check
sleep 3

if pm2 list | grep -q "$PM2_NAME.*online"; then
    echo -e "${GREEN}✅ Sellf is running!${NC}"
else
    echo -e "${RED}❌ Problem starting. Logs:${NC}"
    pm2 logs $PM2_NAME --lines 20
    exit 1
fi

# =============================================================================
# 6. SUMMARY
# =============================================================================

# Check firewall — app binds to :: (all interfaces), iptables must restrict access
if command -v ip6tables >/dev/null 2>&1; then
    FW_POLICY=$(ip6tables -S INPUT 2>/dev/null | grep '^-P INPUT' | awk '{print $3}')
    if [ "$FW_POLICY" != "DROP" ]; then
        echo ""
        echo -e "${YELLOW}⚠️  FIREWALL WARNING: ip6tables INPUT policy = ${FW_POLICY:-UNKNOWN}${NC}"
        echo "   Sellf listens on HOSTNAME=:: (all interfaces)."
        echo "   Port $PORT may be accessible directly from the internet, bypassing Caddy."
        echo "   Run from your local machine: ./local/setup-firewall.sh $SSH_ALIAS"
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
if [ "$RESTART_ONLY" = true ]; then
    echo -e "${GREEN}✅ Sellf restarted!${NC}"
else
    echo -e "${GREEN}✅ Sellf updated!${NC}"
fi
echo "════════════════════════════════════════════════════════════════"
echo ""
if [ "$RESTART_ONLY" = false ]; then
    echo "   Previous version: $CURRENT_VERSION"
    echo "   New version: $NEW_VERSION"
    echo ""
fi
echo "📋 Useful commands:"
echo "   pm2 logs $PM2_NAME - logs"
echo "   pm2 restart $PM2_NAME - restart"
echo "   ./update.sh --restart - restart without updating (e.g. after changing .env)"
echo ""
