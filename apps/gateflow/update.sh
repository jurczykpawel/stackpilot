#!/bin/bash

# StackPilot - GateFlow Update
# Updates GateFlow to the latest version
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/deploy.sh gateflow --ssh=mikrus --update
#   ./local/deploy.sh gateflow --ssh=mikrus --update --build-file=~/Downloads/gateflow-build.tar.gz
#   ./local/deploy.sh gateflow --ssh=mikrus --update --restart (restart without updating)
#
# Environment variables:
#   BUILD_FILE - path to local tar.gz file (instead of downloading from GitHub)
#
# Flags:
#   --restart - only restart the application (e.g. after changing .env), without downloading a new version
#
# Note: Database updates are handled by deploy.sh (Supabase API)

set -e

GITHUB_REPO="jurczykpawel/gateflow"
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
# New location: /opt/stacks/gateflow* (backup-friendly)
# Old location: /root/gateflow* (for compatibility)

find_gateflow_dir() {
    local NAME="$1"
    # Check new location
    if [ -d "/opt/stacks/gateflow-${NAME}" ]; then
        echo "/opt/stacks/gateflow-${NAME}"
    elif [ -d "/root/gateflow-${NAME}" ]; then
        echo "/root/gateflow-${NAME}"
    elif [ -d "/opt/stacks/gateflow" ]; then
        echo "/opt/stacks/gateflow"
    elif [ -d "/root/gateflow" ]; then
        echo "/root/gateflow"
    fi
}

if [ -n "$INSTANCE" ]; then
    INSTALL_DIR=$(find_gateflow_dir "$INSTANCE")
    PM2_NAME="gateflow-${INSTANCE}"
elif ls -d /opt/stacks/gateflow-* &>/dev/null 2>&1; then
    INSTALL_DIR=$(ls -d /opt/stacks/gateflow-* 2>/dev/null | head -1)
    PM2_NAME="gateflow-${INSTALL_DIR##*-}"
elif ls -d /root/gateflow-* &>/dev/null 2>&1; then
    INSTALL_DIR=$(ls -d /root/gateflow-* 2>/dev/null | head -1)
    PM2_NAME="gateflow-${INSTALL_DIR##*-}"
elif [ -d "/opt/stacks/gateflow" ]; then
    INSTALL_DIR="/opt/stacks/gateflow"
    PM2_NAME="$PM2_NAME"
else
    INSTALL_DIR="/root/gateflow"
    PM2_NAME="$PM2_NAME"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
if [ "$RESTART_ONLY" = true ]; then
    echo -e "${BLUE}🔄 GateFlow Restart${NC}"
else
    echo -e "${BLUE}🔄 GateFlow Update${NC}"
fi
echo ""

# =============================================================================
# 1. CHECK IF GATEFLOW IS INSTALLED
# =============================================================================

if [ ! -d "$INSTALL_DIR/admin-panel" ]; then
    echo -e "${RED}❌ GateFlow is not installed${NC}"
    echo "   Use deploy.sh for the first installation."
    exit 1
fi

ENV_FILE="$INSTALL_DIR/admin-panel/.env.local"
STANDALONE_DIR="$INSTALL_DIR/admin-panel/.next/standalone/admin-panel"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Missing .env.local file${NC}"
    exit 1
fi

echo "✅ GateFlow found in $INSTALL_DIR"

# Get current version (if available)
CURRENT_VERSION="unknown"
if [ -f "$INSTALL_DIR/admin-panel/version.txt" ]; then
    CURRENT_VERSION=$(cat "$INSTALL_DIR/admin-panel/version.txt")
fi
echo "   Current version: $CURRENT_VERSION"

# =============================================================================
# 2. DOWNLOAD NEW VERSION (skip in restart mode)
# =============================================================================

if [ "$RESTART_ONLY" = false ]; then
    echo ""

    # Backup old configuration
    cp "$ENV_FILE" "$INSTALL_DIR/.env.local.backup"
    echo "   .env.local backup created"

    # Download to temporary folder
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    cd "$TEMP_DIR"

    # Check if we have a local file
    if [ -n "$BUILD_FILE" ] && [ -f "$BUILD_FILE" ]; then
        echo "📦 Using local file: $BUILD_FILE"
        if ! tar -xzf "$BUILD_FILE"; then
            echo -e "${RED}❌ Failed to extract file${NC}"
            exit 1
        fi
    else
        echo "📥 Downloading from GitHub..."
        RELEASE_URL="https://github.com/$GITHUB_REPO/releases/latest/download/gateflow-build.tar.gz"
        if ! curl -fsSL "$RELEASE_URL" | tar -xz; then
            echo -e "${RED}❌ Failed to download new version${NC}"
            echo ""
            echo "If the repo is private, use --build-file:"
            echo "   ./local/deploy.sh gateflow --ssh=mikrus --update --build-file=~/Downloads/gateflow-build.tar.gz"
            exit 1
        fi
    fi

    if [ ! -d ".next/standalone" ]; then
        echo -e "${RED}❌ Invalid archive structure${NC}"
        exit 1
    fi

    # Check new version
    NEW_VERSION="unknown"
    if [ -f "version.txt" ]; then
        NEW_VERSION=$(cat version.txt)
    fi
    echo "   New version: $NEW_VERSION"

    if [ "$CURRENT_VERSION" = "$NEW_VERSION" ] && [ "$CURRENT_VERSION" != "unknown" ]; then
        echo -e "${YELLOW}⚠️  You already have the latest version ($CURRENT_VERSION)${NC}"
        read -p "Continue anyway? [y/N]: " CONTINUE
        if [[ ! "$CONTINUE" =~ ^[YyTt]$ ]]; then
            echo "Cancelled."
            exit 0
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
echo "⏹️  Stopping GateFlow..."

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

    # Restore .env.local
    cp "$INSTALL_DIR/.env.local.backup" "$ENV_FILE"

    echo -e "${GREEN}✅ Files updated${NC}"
else
    echo ""
    echo "📋 Restart mode - skipped file update"
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
echo "🚀 Starting GateFlow..."

cd "$STANDALONE_DIR"

# Load variables and start
# Clear system HOSTNAME (it's the machine name, not the listen address)
# Without this ${HOSTNAME:-::} never falls back to :: because the system always sets HOSTNAME
unset HOSTNAME
set -a
source .env.local
set +a
export PORT="${PORT:-3333}"
# :: listens on IPv4 and IPv6
export HOSTNAME="${HOSTNAME:-::}"

pm2 delete $PM2_NAME 2>/dev/null || true
# IMPORTANT: use --interpreter node, NOT "node server.js" in quotes
pm2 start server.js --name $PM2_NAME --interpreter node
pm2 save

# Wait and check
sleep 3

if pm2 list | grep -q "$PM2_NAME.*online"; then
    echo -e "${GREEN}✅ GateFlow is running!${NC}"
else
    echo -e "${RED}❌ Problem starting. Logs:${NC}"
    pm2 logs $PM2_NAME --lines 20
    exit 1
fi

# =============================================================================
# 6. SUMMARY
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
if [ "$RESTART_ONLY" = true ]; then
    echo -e "${GREEN}✅ GateFlow restarted!${NC}"
else
    echo -e "${GREEN}✅ GateFlow updated!${NC}"
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
