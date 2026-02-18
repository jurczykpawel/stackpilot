#!/bin/bash

# StackPilot - Supabase Setup for GateFlow
# Configures Supabase and runs migrations
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/setup-supabase-gateflow.sh [ssh_alias]
#
# Examples:
#   ./local/setup-supabase-gateflow.sh vps     # Configuration + migrations on server
#   ./local/setup-supabase-gateflow.sh          # Configuration only

set -e

SSH_ALIAS="${1:-}"
GITHUB_REPO="jurczykpawel/gateflow"
MIGRATIONS_PATH="supabase/migrations"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
CONFIG_DIR="$HOME/.config/gateflow"
CONFIG_FILE="$CONFIG_DIR/supabase.env"

echo ""
echo -e "${BLUE}🗄️  Supabase Setup for GateFlow${NC}"
echo ""

# =============================================================================
# 1. CHECK EXISTING CONFIGURATION
# =============================================================================

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_ANON_KEY" ] && [ -n "$SUPABASE_SERVICE_KEY" ]; then
        echo -e "${GREEN}✅ Found saved Supabase configuration${NC}"
        echo "   URL: $SUPABASE_URL"
        echo ""
        read -p "Use existing configuration? [Y/n]: " USE_EXISTING
        if [[ ! "$USE_EXISTING" =~ ^[Nn]$ ]]; then
            echo ""
            echo -e "${GREEN}✅ Using saved configuration${NC}"

            # Proceed to migrations
            if [ -n "$SSH_ALIAS" ]; then
                echo ""
                read -p "Run migrations on server $SSH_ALIAS? [Y/n]: " RUN_MIGRATIONS
                if [[ ! "$RUN_MIGRATIONS" =~ ^[Nn]$ ]]; then
                    # Check DATABASE_URL
                    if [ -z "$DATABASE_URL" ]; then
                        echo ""
                        echo "I need a Database URL to run migrations."
                        echo ""
                        echo "Where to find it:"
                        echo "   1. Open: https://supabase.com/dashboard"
                        echo "   2. Select project → Settings → Database"
                        echo "   3. Section 'Connection string' → URI"
                        echo ""
                        read -p "Paste Database URL (postgresql://...): " DATABASE_URL

                        if [ -n "$DATABASE_URL" ]; then
                            # Save to config
                            echo "DATABASE_URL='$DATABASE_URL'" >> "$CONFIG_FILE"
                            chmod 600 "$CONFIG_FILE"
                        fi
                    fi

                    if [ -n "$DATABASE_URL" ]; then
                        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                        DATABASE_URL="$DATABASE_URL" "$SCRIPT_DIR/setup-supabase-migrations.sh" "$SSH_ALIAS"
                    fi
                fi
            fi

            echo ""
            echo -e "${GREEN}🎉 Supabase configured!${NC}"
            echo ""
            echo "Variables for deploy.sh:"
            echo "   SUPABASE_URL='$SUPABASE_URL'"
            echo "   SUPABASE_ANON_KEY='$SUPABASE_ANON_KEY'"
            echo "   SUPABASE_SERVICE_KEY='$SUPABASE_SERVICE_KEY'"
            exit 0
        fi
    fi
fi

# =============================================================================
# 2. CREATE SUPABASE PROJECT
# =============================================================================

echo "GateFlow requires a Supabase project (the free plan is sufficient)."
echo ""
echo "If you don't have a project yet, create one now:"
echo "   1. Open: https://supabase.com/dashboard"
echo "   2. Click 'New Project'"
echo "   3. Select organization and region (e.g. Frankfurt)"
echo "   4. Enter a name (e.g. 'gateflow')"
echo "   5. Generate a strong database password"
echo "   6. Click 'Create new project'"
echo ""

read -p "Press Enter to open Supabase..." _

if command -v open &>/dev/null; then
    open "https://supabase.com/dashboard"
elif command -v xdg-open &>/dev/null; then
    xdg-open "https://supabase.com/dashboard"
fi

# =============================================================================
# 3. GET API KEYS
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📋 API KEYS"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Find them in: Project Settings → API"
echo ""

# SUPABASE_URL
echo "1. Project URL (e.g. https://xxxxx.supabase.co)"
read -p "   SUPABASE_URL: " SUPABASE_URL

if [ -z "$SUPABASE_URL" ]; then
    echo -e "${RED}❌ SUPABASE_URL is required${NC}"
    exit 1
fi

# URL validation
if [[ ! "$SUPABASE_URL" =~ ^https://.*\.supabase\.co$ ]]; then
    echo -e "${YELLOW}⚠️  URL looks unusual (should be https://xxx.supabase.co)${NC}"
    read -p "   Continue? [y/N]: " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[TtYy]$ ]]; then
        exit 1
    fi
fi

# ANON KEY
echo ""
echo "2. anon public (starts with eyJ...)"
read -p "   SUPABASE_ANON_KEY: " SUPABASE_ANON_KEY

if [ -z "$SUPABASE_ANON_KEY" ]; then
    echo -e "${RED}❌ SUPABASE_ANON_KEY is required${NC}"
    exit 1
fi

# SERVICE KEY
echo ""
echo "3. service_role (also starts with eyJ..., NOTE: this is a secret!)"
read -p "   SUPABASE_SERVICE_KEY: " SUPABASE_SERVICE_KEY

if [ -z "$SUPABASE_SERVICE_KEY" ]; then
    echo -e "${RED}❌ SUPABASE_SERVICE_KEY is required${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ API keys obtained${NC}"

# =============================================================================
# 4. GET DATABASE URL (for migrations)
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📋 DATABASE URL (for migrations)"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Find it in: Project Settings → Database → Connection string → URI"
echo "(starts with postgresql://)"
echo ""
read -p "DATABASE_URL (or Enter to skip migrations): " DATABASE_URL

# =============================================================================
# 5. SAVE CONFIGURATION
# =============================================================================

echo ""
echo "💾 Saving configuration..."

mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
# GateFlow - Supabase Configuration
# Generated: $(date)

SUPABASE_URL='$SUPABASE_URL'
SUPABASE_ANON_KEY='$SUPABASE_ANON_KEY'
SUPABASE_SERVICE_KEY='$SUPABASE_SERVICE_KEY'
EOF

if [ -n "$DATABASE_URL" ]; then
    echo "DATABASE_URL='$DATABASE_URL'" >> "$CONFIG_FILE"
fi

chmod 600 "$CONFIG_FILE"
echo -e "${GREEN}✅ Configuration saved in $CONFIG_FILE${NC}"

# =============================================================================
# 6. RUN MIGRATIONS (optional)
# =============================================================================

if [ -n "$DATABASE_URL" ] && [ -n "$SSH_ALIAS" ]; then
    echo ""
    read -p "Run migrations on server $SSH_ALIAS? [Y/n]: " RUN_MIGRATIONS
    if [[ ! "$RUN_MIGRATIONS" =~ ^[Nn]$ ]]; then
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        DATABASE_URL="$DATABASE_URL" "$SCRIPT_DIR/setup-supabase-migrations.sh" "$SSH_ALIAS"
    fi
elif [ -n "$DATABASE_URL" ]; then
    echo ""
    read -p "Run migrations locally (requires Docker)? [Y/n]: " RUN_MIGRATIONS
    if [[ ! "$RUN_MIGRATIONS" =~ ^[Nn]$ ]]; then
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        DATABASE_URL="$DATABASE_URL" "$SCRIPT_DIR/setup-supabase-migrations.sh"
    fi
fi

# =============================================================================
# 7. SUMMARY
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "${GREEN}🎉 Supabase configured!${NC}"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Configuration saved in: $CONFIG_FILE"
echo ""
echo "Usage with deploy.sh:"
echo "   source ~/.config/gateflow/supabase.env"
echo "   ./local/deploy.sh gateflow --ssh=vps --domain=gf.example.com"
echo ""
echo "Or manually:"
echo "   SUPABASE_URL='$SUPABASE_URL' \\"
echo "   SUPABASE_ANON_KEY='$SUPABASE_ANON_KEY' \\"
echo "   SUPABASE_SERVICE_KEY='$SUPABASE_SERVICE_KEY' \\"
echo "   ./local/deploy.sh gateflow --ssh=vps --domain=gf.example.com"
echo ""
