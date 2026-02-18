#!/bin/bash

# StackPilot - Supabase Migrations (via API)
# Prepares the database for GateFlow
# Author: Paweł (Lazy Engineer)
#
# Uses Supabase Management API - does not require DATABASE_URL or psql
# Only needs SUPABASE_URL and Personal Access Token
#
# Usage:
#   ./local/setup-supabase-migrations.sh
#
# Environment variables (optional - can be provided interactively):
#   SUPABASE_URL - Project URL (https://xxx.supabase.co)
#   SUPABASE_ACCESS_TOKEN - Personal Access Token

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

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
echo -e "${BLUE}🗄️  Database Preparation${NC}"
echo ""

# =============================================================================
# 1. GET CONFIGURATION
# =============================================================================

# Preserve values from env (they take priority over config)
ENV_PROJECT_REF="$PROJECT_REF"
ENV_SUPABASE_URL="$SUPABASE_URL"

# Load saved configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Restore values from env if they were set (env > config)
[ -n "$ENV_PROJECT_REF" ] && PROJECT_REF="$ENV_PROJECT_REF"
[ -n "$ENV_SUPABASE_URL" ] && SUPABASE_URL="$ENV_SUPABASE_URL"

# Check SUPABASE_URL
if [ -z "$SUPABASE_URL" ]; then
    echo -e "${RED}❌ Missing SUPABASE_URL${NC}"
    echo "   First run the GateFlow installation or setup-supabase-gateflow.sh"
    exit 1
fi

# Use PROJECT_REF from config or extract from URL
if [ -z "$PROJECT_REF" ]; then
    PROJECT_REF=$(echo "$SUPABASE_URL" | sed -E 's|https://([^.]+)\.supabase\.co.*|\1|')
fi

if [ -z "$PROJECT_REF" ] || [ "$PROJECT_REF" = "$SUPABASE_URL" ]; then
    echo -e "${RED}❌ Cannot extract project ref from URL: $SUPABASE_URL${NC}"
    exit 1
fi

echo "   Project: $PROJECT_REF"

# Check Personal Access Token
if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
    # Check in main config (where we save tokens)
    SUPABASE_TOKEN_FILE="$HOME/.config/supabase/access_token"
    if [ -f "$SUPABASE_TOKEN_FILE" ]; then
        SUPABASE_ACCESS_TOKEN=$(cat "$SUPABASE_TOKEN_FILE")
    fi
fi

if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
    echo ""
    echo -e "${YELLOW}⚠️  Missing Personal Access Token${NC}"
    echo ""
    echo "A token is needed to make changes to the database."
    echo ""
    echo "Where to find it:"
    echo "   1. Open: https://supabase.com/dashboard/account/tokens"
    echo "   2. Click 'Generate new token'"
    echo "   3. Copy the token"
    echo ""

    read -p "Press Enter to open Supabase..." _
    if command -v open &>/dev/null; then
        open "https://supabase.com/dashboard/account/tokens"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "https://supabase.com/dashboard/account/tokens"
    fi

    echo ""
    read -p "Paste Personal Access Token: " SUPABASE_ACCESS_TOKEN

    if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
        echo -e "${RED}❌ Token is required${NC}"
        exit 1
    fi

    # Save token
    mkdir -p "$HOME/.config/supabase"
    echo "$SUPABASE_ACCESS_TOKEN" > "$SUPABASE_TOKEN_FILE"
    chmod 600 "$SUPABASE_TOKEN_FILE"
    echo "   ✅ Token saved"
fi

# =============================================================================
# 2. SQL EXECUTION FUNCTION
# =============================================================================

run_sql() {
    local SQL="$1"

    RESPONSE=$(curl -s -X POST "https://api.supabase.com/v1/projects/$PROJECT_REF/database/query" \
        -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"query\": $(echo "$SQL" | jq -Rs .)}")

    # Check for errors
    if echo "$RESPONSE" | grep -q '"error"'; then
        ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        echo -e "${RED}❌ SQL Error: $ERROR${NC}" >&2
        return 1
    fi

    echo "$RESPONSE"
}

# Test connection
echo ""
echo "🔍 Checking database connection..."

TEST_RESULT=$(run_sql "SELECT 1 as test" 2>&1)
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Cannot connect to the database${NC}"
    echo "   Check if the token is valid"
    exit 1
fi

echo -e "${GREEN}✅ Connection OK${NC}"

# =============================================================================
# 3. FIND MIGRATIONS (locally or from GitHub)
# =============================================================================

echo ""
echo "📥 Looking for migration files..."

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Check if migrations are on the server (from the installation package)
SSH_ALIAS="${SSH_ALIAS:-vps}"
MIGRATIONS_SOURCE=""

# Find GateFlow installation directory
# New location: /opt/stacks/gateflow*
# Old location: /root/gateflow* (for compatibility)
GATEFLOW_DIR=$(server_exec "ls -d /opt/stacks/gateflow-* 2>/dev/null | head -1" 2>/dev/null)
if [ -z "$GATEFLOW_DIR" ]; then
    GATEFLOW_DIR=$(server_exec "ls -d /opt/stacks/gateflow 2>/dev/null" 2>/dev/null)
fi
if [ -z "$GATEFLOW_DIR" ]; then
    # Fallback to old location
    GATEFLOW_DIR=$(server_exec "ls -d /root/gateflow-* 2>/dev/null | head -1" 2>/dev/null)
fi
if [ -z "$GATEFLOW_DIR" ]; then
    GATEFLOW_DIR="/root/gateflow"
fi
REMOTE_MIGRATIONS_DIR="$GATEFLOW_DIR/admin-panel/supabase/migrations"

# Get migration list from server via SSH
MIGRATIONS_LIST=$(server_exec "ls '$REMOTE_MIGRATIONS_DIR'/*.sql 2>/dev/null | xargs -n1 basename 2>/dev/null | sort" 2>/dev/null)

if [ -n "$MIGRATIONS_LIST" ]; then
    echo "   ✅ Found migrations in the installation package"
    MIGRATIONS_SOURCE="server"
    # Copy from server to temp
    if is_on_server; then
        cp "$REMOTE_MIGRATIONS_DIR/"*.sql "$TEMP_DIR/" 2>/dev/null
    else
        scp -q "$SSH_ALIAS:$REMOTE_MIGRATIONS_DIR/"*.sql "$TEMP_DIR/" 2>/dev/null
    fi
fi

# Fallback - download from GitHub
if [ -z "$MIGRATIONS_SOURCE" ]; then
    echo "   Downloading from GitHub..."
    MIGRATIONS_LIST=$(curl -sL "https://api.github.com/repos/$GITHUB_REPO/contents/$MIGRATIONS_PATH" \
        -H "Authorization: token ${GITHUB_TOKEN:-}" 2>/dev/null | grep -o '"name": "[^"]*\.sql"' | cut -d'"' -f4 | sort)

    if [ -z "$MIGRATIONS_LIST" ]; then
        echo -e "${YELLOW}⚠️  No migrations to run${NC}"
        echo "   Migrations are not available locally or on GitHub."
        exit 0
    fi

    # Download each file
    for migration in $MIGRATIONS_LIST; do
        curl -sL "https://raw.githubusercontent.com/$GITHUB_REPO/main/$MIGRATIONS_PATH/$migration" \
            -H "Authorization: token ${GITHUB_TOKEN:-}" \
            -o "$TEMP_DIR/$migration"
    done
    MIGRATIONS_SOURCE="github"
fi

echo "   Found migrations:"
for migration in $MIGRATIONS_LIST; do
    echo "   - $migration"
done

# =============================================================================
# 4. CHECK WHICH MIGRATIONS ARE NEEDED
# =============================================================================

echo ""
echo "🔍 Checking database status..."

# We use the Supabase CLI table: supabase_migrations.schema_migrations
# This keeps migrations consistent with `supabase migration up`
APPLIED_MIGRATIONS=""

# Check if supabase_migrations schema exists
SCHEMA_CHECK=$(run_sql "SELECT EXISTS (SELECT FROM information_schema.schemata WHERE schema_name = 'supabase_migrations');" 2>/dev/null)

if echo "$SCHEMA_CHECK" | grep -q "true"; then
    echo "   Supabase migrations table exists"
    APPLIED_RESULT=$(run_sql "SELECT version FROM supabase_migrations.schema_migrations ORDER BY version;" 2>/dev/null)
    APPLIED_MIGRATIONS=$(echo "$APPLIED_RESULT" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')

    if [ -n "$APPLIED_MIGRATIONS" ]; then
        echo "   Already applied: $(echo $APPLIED_MIGRATIONS | wc -w | tr -d ' ') migrations"
    fi
else
    echo "   Fresh installation - creating migrations table..."
    # Create schema and table compatible with Supabase CLI
    run_sql "CREATE SCHEMA IF NOT EXISTS supabase_migrations;" > /dev/null
    run_sql "CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (version TEXT PRIMARY KEY, name TEXT, statements TEXT[]);" > /dev/null
    echo "   ✅ Created supabase_migrations.schema_migrations"
fi

# Determine which migrations need to be run
PENDING_MIGRATIONS=""
for migration in $MIGRATIONS_LIST; do
    VERSION=$(echo "$migration" | cut -d'_' -f1)
    if ! echo "$APPLIED_MIGRATIONS" | grep -q "$VERSION"; then
        PENDING_MIGRATIONS="$PENDING_MIGRATIONS $migration"
    fi
done

PENDING_MIGRATIONS=$(echo "$PENDING_MIGRATIONS" | xargs)

if [ -z "$PENDING_MIGRATIONS" ]; then
    echo ""
    echo -e "${GREEN}✅ Database is up to date${NC}"
    exit 0
fi

echo ""
echo "📋 Pending:"
for migration in $PENDING_MIGRATIONS; do
    echo -e "   ${YELLOW}→ $migration${NC}"
done

# =============================================================================
# 5. RUN MIGRATIONS
# =============================================================================

echo ""
echo "🚀 Running..."

for migration in $PENDING_MIGRATIONS; do
    VERSION=$(echo "$migration" | cut -d'_' -f1)
    echo -n "   $migration... "

    SQL_CONTENT=$(cat "$TEMP_DIR/$migration")

    if run_sql "$SQL_CONTENT" > /dev/null 2>&1; then
        # Record in Supabase CLI table
        NAME=$(echo "$migration" | sed 's/^[0-9]*_//' | sed 's/\.sql$//')
        run_sql "INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES ('$VERSION', '$NAME');" > /dev/null 2>&1
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
        echo -e "${RED}   Error in migration $migration${NC}"
        exit 1
    fi
done

echo ""
echo -e "${GREEN}🎉 Database prepared!${NC}"
