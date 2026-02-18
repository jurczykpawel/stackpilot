#!/bin/bash

# StackPilot - Database Setup Helper
# Used by installation scripts to configure the database.
# Author: Paweł (Lazy Engineer)
#
# NEW FLOW with CLI:
#   1. parse_args() + load_defaults()  - from cli-parser.sh
#   2. ask_database()    - checks flags, only asks when missing
#   3. fetch_database()  - fetches data from API (if shared)
#
# CLI flags:
#   --db-source=shared|custom
#   --db-host=HOST --db-port=PORT --db-name=NAME
#   --db-schema=SCHEMA --db-user=USER --db-pass=PASS
#
# Available variables after calling:
#   $DB_HOST, $DB_PORT, $DB_NAME, $DB_SCHEMA, $DB_USER, $DB_PASS, $DB_SOURCE

# Load cli-parser if not loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! type ask_if_empty &>/dev/null; then
    source "$SCRIPT_DIR/cli-parser.sh"
fi

# Colors (if not defined by cli-parser)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
NC="${NC:-\033[0m}"

# Exported variables (don't reset if already set)
export DB_HOST="${DB_HOST:-}"
export DB_PORT="${DB_PORT:-}"
export DB_NAME="${DB_NAME:-}"
export DB_SCHEMA="${DB_SCHEMA:-}"
export DB_USER="${DB_USER:-}"
export DB_PASS="${DB_PASS:-}"
export DB_SOURCE="${DB_SOURCE:-}"

# Applications requiring pgcrypto (don't work with the shared database)
# n8n from version 1.121+ requires gen_random_uuid() which needs pgcrypto or PostgreSQL 13+
# listmonk from v6.0.0 requires pgcrypto for migrations
REQUIRES_PGCRYPTO="umami n8n listmonk"

# =============================================================================
# DATABASE RECOMMENDATIONS FOR APPLICATIONS
# =============================================================================
# Recommendations are displayed to the user during database selection.
# They help make an informed decision whether to use the free or paid database.
# =============================================================================

# Get recommendation for application (uses case instead of declare -A for bash 3.x compatibility)
get_db_recommendation() {
    local APP_NAME="$1"
    case "$APP_NAME" in
        n8n|umami)
            echo "Requires a dedicated PostgreSQL database with the pgcrypto extension.
   The free shared database does NOT support this application.
   Use a dedicated PostgreSQL instance."
            ;;
        listmonk)
            echo "Requires a dedicated PostgreSQL database with the pgcrypto extension.
   The free shared database does NOT support this application (since v6.0.0).
   Use a dedicated PostgreSQL instance."
            ;;
        nocodb)
            echo "NocoDB only stores table and view metadata.
   Actual data can be kept in an external database.
   The free shared database is sufficient for typical usage.
   Paid: if you have many tables/collaborators"
            ;;
        cap)
            echo "Cap only stores recording metadata (S3 links).
   Actual video files are in S3/MinIO.
   The free shared database is more than sufficient!
   Paid: only with a very large number of recordings"
            ;;
        typebot)
            echo "Typebot stores bots, results, and analytics.
   Free shared database is OK for small/medium bots.
   Paid: if you plan >10k conversations/month."
            ;;
        postiz)
            echo "Postiz stores social media account configs and scheduled posts.
   The free shared database should be sufficient for typical usage.
   Paid: if you plan a very large number of posts/accounts"
            ;;
        wordpress)
            echo "WordPress stores content, users, and settings.
   The free shared MySQL is sufficient for small/medium sites.
   Paid: if you have many plugins/traffic"
            ;;
    esac
}

# Get default database type for application
get_default_db_type() {
    local APP_NAME="$1"
    case "$APP_NAME" in
        n8n|umami|listmonk)
            echo "custom"  # Requires pgcrypto - shared won't work
            ;;
        nocodb|cap|typebot|postiz|wordpress)
            echo "shared"  # Lightweight apps - shared is sufficient
            ;;
        *)
            echo "shared"  # Default to shared
            ;;
    esac
}

# =============================================================================
# PHASE 1: Gathering information (respects CLI flags)
# =============================================================================

ask_database() {
    local DB_TYPE="${1:-postgres}"
    local APP_NAME="${2:-}"

    # Set default schema to app name (if not provided)
    if [ -z "$DB_SCHEMA" ] && [ -n "$APP_NAME" ]; then
        DB_SCHEMA="$APP_NAME"
    fi
    DB_SCHEMA="${DB_SCHEMA:-public}"

    # Check if application requires pgcrypto
    local SHARED_BLOCKED=false
    if [[ " $REQUIRES_PGCRYPTO " == *" $APP_NAME "* ]]; then
        SHARED_BLOCKED=true
    fi

    # Get recommendation for this application
    local RECOMMENDATION=""
    if [ -n "$APP_NAME" ]; then
        RECOMMENDATION=$(get_db_recommendation "$APP_NAME")
    fi

    # If DB_SOURCE already set from CLI
    if [ -n "$DB_SOURCE" ]; then
        # Validation: shared blocked for some apps
        if [ "$DB_SOURCE" = "shared" ] && [ "$SHARED_BLOCKED" = true ]; then
            echo -e "${RED}Error: $APP_NAME requires a dedicated database (--db-source=custom)${NC}" >&2
            echo "   The shared database does not support pgcrypto." >&2
            echo "   Please use a dedicated PostgreSQL instance." >&2
            return 1
        fi

        # Validation: custom requires full credentials
        if [ "$DB_SOURCE" = "custom" ]; then
            if [ -z "$DB_HOST" ] || [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
                if [ "$YES_MODE" = true ]; then
                    echo -e "${RED}Error: --db-source=custom requires --db-host, --db-name, --db-user, --db-pass${NC}" >&2
                    return 1
                fi
                # Interactive mode - ask for missing values
                ask_custom_db "$DB_TYPE" "$APP_NAME"
                return $?
            fi
        fi

        echo -e "${GREEN}✅ Database: $DB_SOURCE (schema: $DB_SCHEMA)${NC}"
        return 0
    fi

    # --yes mode without --db-source = error
    if [ "$YES_MODE" = true ]; then
        echo -e "${RED}Error: --db-source is required in --yes mode${NC}" >&2
        return 1
    fi

    # Interactive mode
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  🗄️  Database configuration ($DB_TYPE)"
    echo "╚════════════════════════════════════════════════════════════════╝"

    # Show recommendation for application
    if [ -n "$RECOMMENDATION" ]; then
        echo ""
        echo -e "${YELLOW}💡 Recommendation for $APP_NAME:${NC}"
        echo "$RECOMMENDATION"
    fi

    echo ""
    echo "Where should the database be hosted?"
    echo ""

    if [ "$SHARED_BLOCKED" = true ]; then
        echo "  1) 🚫 Shared database (UNAVAILABLE)"
        echo "     $APP_NAME requires the pgcrypto extension"
        echo ""
    else
        echo "  1) 🆓 Shared database (free)"
        echo "     Will automatically fetch credentials from API"
        echo ""
    fi

    echo "  2) 💰 Own/dedicated database"
    echo "     You will provide your own connection details"
    echo ""

    # Set default choice based on recommendation
    local DEFAULT_TYPE=$(get_default_db_type "$APP_NAME")
    local DEFAULT_CHOICE="1"
    if [ "$DEFAULT_TYPE" = "custom" ] || [ "$SHARED_BLOCKED" = true ]; then
        DEFAULT_CHOICE="2"
    fi

    read -p "Choose option [1-2, default $DEFAULT_CHOICE]: " DB_CHOICE
    DB_CHOICE="${DB_CHOICE:-$DEFAULT_CHOICE}"

    case $DB_CHOICE in
        1)
            if [ "$SHARED_BLOCKED" = true ]; then
                echo ""
                echo -e "${RED}❌ $APP_NAME does not work with the shared database!${NC}"
                echo "   Requires the pgcrypto extension (not available in the free database)."
                echo ""
                echo "   Please use a dedicated PostgreSQL instance."
                echo ""
                return 1
            fi
            export DB_SOURCE="shared"
            echo ""
            echo -e "${GREEN}✅ Selected: shared database${NC}"
            echo -e "${BLUE}ℹ️  Schema: $DB_SCHEMA${NC}"
            return 0
            ;;
        2)
            export DB_SOURCE="custom"
            ask_custom_db "$DB_TYPE" "$APP_NAME"
            return $?
            ;;
        *)
            echo -e "${RED}❌ Invalid choice${NC}"
            return 1
            ;;
    esac
}

ask_custom_db() {
    local DB_TYPE="$1"
    local APP_NAME="${2:-}"

    echo ""
    echo -e "${YELLOW}📝 Enter your database credentials${NC}"
    echo ""

    # Default schema = app name
    local DEFAULT_SCHEMA="${APP_NAME:-public}"

    if [ "$DB_TYPE" = "postgres" ]; then
        ask_if_empty DB_HOST "Host (e.g. psql.example.com)"
        ask_if_empty DB_PORT "Port" "5432"
        ask_if_empty DB_NAME "Database name"
        ask_if_empty DB_SCHEMA "Schema" "$DEFAULT_SCHEMA"
        ask_if_empty DB_USER "User"
        ask_if_empty DB_PASS "Password" "" true

    elif [ "$DB_TYPE" = "mysql" ]; then
        ask_if_empty DB_HOST "Host (e.g. mysql.example.com)"
        ask_if_empty DB_PORT "Port" "3306"
        ask_if_empty DB_NAME "Database name"
        ask_if_empty DB_USER "User"
        ask_if_empty DB_PASS "Password" "" true

    elif [ "$DB_TYPE" = "mongo" ]; then
        ask_if_empty DB_HOST "Host (e.g. mongo.example.com)"
        ask_if_empty DB_PORT "Port" "27017"
        ask_if_empty DB_NAME "Database name"
        ask_if_empty DB_USER "User"
        ask_if_empty DB_PASS "Password" "" true

    else
        echo -e "${RED}❌ Unknown database type: $DB_TYPE${NC}"
        return 1
    fi

    # Validation
    if [ -z "$DB_HOST" ] || [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
        echo -e "${RED}❌ All fields are required${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}✅ Credentials saved${NC}"
    if [ "$DB_TYPE" = "postgres" ] && [ -n "$DB_SCHEMA" ] && [ "$DB_SCHEMA" != "public" ]; then
        echo -e "${BLUE}ℹ️  Schema: $DB_SCHEMA${NC}"
    fi

    # Export variables
    export DB_HOST DB_PORT DB_NAME DB_SCHEMA DB_USER DB_PASS

    return 0
}

# =============================================================================
# CHECKING EXISTING SCHEMAS
# =============================================================================

# Check if schema exists and contains tables (PostgreSQL)
# Usage: check_schema_exists SSH_ALIAS APP_NAME
# Returns: 0 if schema exists and has tables, 1 otherwise
check_schema_exists() {
    local SSH_ALIAS="${1:-${SSH_ALIAS:-vps}}"
    local APP_NAME="${2:-}"
    local SCHEMA="${DB_SCHEMA:-$APP_NAME}"

    # Skip for dry-run
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[dry-run] Checking schema '$SCHEMA' in database${NC}"
        return 1
    fi

    # We need DB credentials
    if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
        return 1
    fi

    # Schema validation (preventing SQL injection)
    if ! [[ "$SCHEMA" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "${RED}Error: Invalid schema name: $SCHEMA${NC}" >&2
        return 1
    fi

    # Escape single quotes in DB_PASS (preventing shell injection)
    local ESCAPED_PASS="${DB_PASS//\'/\'\\\'\'}"

    # Check via SSH if schema exists and has tables
    local TABLE_COUNT=$(ssh "$SSH_ALIAS" "PGPASSWORD='$ESCAPED_PASS' psql -h '$DB_HOST' -p '${DB_PORT:-5432}' -U '$DB_USER' -d '$DB_NAME' -t -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$SCHEMA';\"" 2>/dev/null | tr -d ' ')

    if [ -n "$TABLE_COUNT" ] && [ "$TABLE_COUNT" -gt 0 ]; then
        return 0  # Schema exists and has tables
    fi

    return 1  # Schema does not exist or is empty
}

# Warn user if schema exists
# Usage: warn_if_schema_exists SSH_ALIAS APP_NAME
# Returns: 0 if user confirmed or schema doesn't exist, 1 if cancelled
warn_if_schema_exists() {
    local SSH_ALIAS="${1:-${SSH_ALIAS:-vps}}"
    local APP_NAME="${2:-}"
    local SCHEMA="${DB_SCHEMA:-$APP_NAME}"

    # Skip for --yes mode (automatically continue)
    if [ "$YES_MODE" = true ]; then
        return 0
    fi

    # Skip for dry-run
    if [ "$DRY_RUN" = true ]; then
        return 0
    fi

    # Check if schema exists
    if ! check_schema_exists "$SSH_ALIAS" "$APP_NAME"; then
        return 0  # Schema doesn't exist - OK
    fi

    # Schema exists - warn the user
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠️   WARNING: Schema '$SCHEMA' already exists in the database!  ${NC}"
    echo -e "${YELLOW}╠════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║  The schema contains data from a previous installation.        ${NC}"
    echo -e "${YELLOW}║  Continuing may OVERWRITE existing data!                       ${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    read -p "Are you sure you want to continue? (y/N): " CONFIRM
    case "$CONFIRM" in
        [tTyY]|[tT][aA][kK])
            echo -e "${YELLOW}⚠️  Continuing installation - existing data may be modified${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}❌ Installation cancelled${NC}"
            echo "   You can use --db-schema=OTHER_NAME to install in a new schema."
            return 1
            ;;
    esac
}

# =============================================================================
# PHASE 2: Fetching data (heavy operations)
# =============================================================================

fetch_database() {
    local DB_TYPE="${1:-postgres}"
    local SSH_ALIAS="${2:-${SSH_ALIAS:-vps}}"

    # If custom - data is already available, nothing to do
    if [ "$DB_SOURCE" = "custom" ]; then
        return 0
    fi

    # Shared - fetch from API
    if [ "$DB_SOURCE" = "shared" ]; then
        fetch_shared_db "$DB_TYPE" "$SSH_ALIAS"
        return $?
    fi

    echo -e "${RED}❌ Unknown database source: $DB_SOURCE${NC}"
    return 1
}

fetch_shared_db() {
    local DB_TYPE="$1"
    local SSH_ALIAS="$2"

    # Dry-run mode
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[dry-run] Fetching database credentials from API (ssh $SSH_ALIAS)${NC}"
        DB_HOST="[dry-run-host]"
        DB_PORT="5432"
        DB_NAME="[dry-run-db]"
        DB_USER="[dry-run-user]"
        DB_PASS="[dry-run-pass]"
        export DB_HOST DB_PORT DB_NAME DB_USER DB_PASS
        return 0
    fi

    echo "🔑 Fetching database credentials from API..."

    # Get API key
    local API_KEY=$(ssh "$SSH_ALIAS" 'cat /klucz_api 2>/dev/null' 2>/dev/null)

    if [ -z "$API_KEY" ]; then
        echo -e "${RED}❌ API key not found on the server!${NC}"
        echo "   Make sure the API is enabled on your server."
        return 1
    fi

    # Get server hostname
    local HOSTNAME=$(ssh "$SSH_ALIAS" 'hostname' 2>/dev/null)

    if [ -z "$HOSTNAME" ]; then
        echo -e "${RED}❌ Failed to connect to the server${NC}"
        return 1
    fi

    # Call API
    local RESPONSE=$(curl -s -d "srv=$HOSTNAME&key=$API_KEY" https://api.mikr.us/db.bash)

    if [ -z "$RESPONSE" ]; then
        echo -e "${RED}❌ No response from API${NC}"
        return 1
    fi

    # Parse response depending on database type
    if [ "$DB_TYPE" = "postgres" ]; then
        local SECTION=$(echo "$RESPONSE" | grep -A4 "^psql=")
        DB_HOST=$(echo "$SECTION" | grep 'Server:' | head -1 | sed 's/.*Server: *//' | tr -d '"')
        DB_USER=$(echo "$SECTION" | grep 'login:' | head -1 | sed 's/.*login: *//')
        DB_PASS=$(echo "$SECTION" | grep 'Haslo:' | head -1 | sed 's/.*Haslo: *//')
        DB_NAME=$(echo "$SECTION" | grep 'Baza:' | head -1 | sed 's/.*Baza: *//' | tr -d '"')
        DB_PORT="5432"

        if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ]; then
            echo -e "${RED}❌ PostgreSQL database is not active!${NC}"
            echo ""
            echo "   Please enable it in your hosting provider's control panel."
            echo ""
            echo "   After enabling, run the installation again."
            return 1
        fi

    elif [ "$DB_TYPE" = "mysql" ]; then
        local SECTION=$(echo "$RESPONSE" | grep -A4 "^mysql=")
        DB_HOST=$(echo "$SECTION" | grep 'Server:' | head -1 | sed 's/.*Server: *//' | tr -d '"')
        DB_USER=$(echo "$SECTION" | grep 'login:' | head -1 | sed 's/.*login: *//')
        DB_PASS=$(echo "$SECTION" | grep 'Haslo:' | head -1 | sed 's/.*Haslo: *//')
        DB_NAME=$(echo "$SECTION" | grep 'Baza:' | head -1 | sed 's/.*Baza: *//' | tr -d '"')
        DB_PORT="3306"

        if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ]; then
            echo -e "${RED}❌ MySQL database is not active!${NC}"
            echo ""
            echo "   Please enable it in your hosting provider's control panel."
            echo ""
            echo "   After enabling, run the installation again."
            return 1
        fi

    elif [ "$DB_TYPE" = "mongo" ]; then
        local SECTION=$(echo "$RESPONSE" | grep -A6 "^mongo=")
        DB_HOST=$(echo "$SECTION" | grep 'Host:' | head -1 | sed 's/.*Host: *//')
        DB_PORT=$(echo "$SECTION" | grep 'Port:' | head -1 | sed 's/.*Port: *//')
        DB_USER=$(echo "$SECTION" | grep 'Login:' | head -1 | sed 's/.*Login: *//')
        DB_PASS=$(echo "$SECTION" | grep 'Haslo:' | head -1 | sed 's/.*Haslo: *//')
        DB_NAME=$(echo "$SECTION" | grep 'Baza:' | head -1 | sed 's/.*Baza: *//')

        if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ]; then
            echo -e "${RED}❌ MongoDB database is not active!${NC}"
            echo ""
            echo "   Please enable it in your hosting provider's control panel."
            echo ""
            echo "   After enabling, run the installation again."
            return 1
        fi
    else
        echo -e "${RED}❌ Unknown database type: $DB_TYPE${NC}"
        echo "   Supported: postgres, mysql, mongo"
        return 1
    fi

    echo -e "${GREEN}✅ Credentials fetched from API${NC}"

    # Export variables
    export DB_HOST DB_PORT DB_NAME DB_USER DB_PASS

    return 0
}

# =============================================================================
# HELPER: DB configuration summary
# =============================================================================

show_db_summary() {
    echo ""
    echo "📋 Database configuration:"
    echo "   Source: $DB_SOURCE"
    echo "   Host:   $DB_HOST"
    echo "   Port:   $DB_PORT"
    echo "   DB:     $DB_NAME"
    if [ -n "$DB_SCHEMA" ] && [ "$DB_SCHEMA" != "public" ]; then
        echo "   Schema: $DB_SCHEMA"
    fi
    echo "   User:   $DB_USER"
    echo "   Pass:   ****${DB_PASS: -4}"
    echo ""
}

# =============================================================================
# OLD FLOW (backward compatibility)
# =============================================================================

setup_database() {
    local DB_TYPE="${1:-postgres}"
    local SSH_ALIAS="${2:-${SSH_ALIAS:-vps}}"
    local APP_NAME="${3:-}"

    # Phase 1: gather data
    if ! ask_database "$DB_TYPE" "$APP_NAME"; then
        return 1
    fi

    # Phase 2: fetch from API (if shared)
    if ! fetch_database "$DB_TYPE" "$SSH_ALIAS"; then
        return 1
    fi

    # Show summary
    show_db_summary

    return 0
}

# Alias for compatibility
setup_shared_db() {
    DB_SOURCE="shared"
    fetch_shared_db "$@"
}

setup_custom_db() {
    DB_SOURCE="custom"
    ask_custom_db "$@"
}

# Helper for generating connection string
get_postgres_url() {
    local SCHEMA="${DB_SCHEMA:-public}"
    if [ "$SCHEMA" = "public" ]; then
        echo "postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    else
        echo "postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?schema=${SCHEMA}"
    fi
}

# Version without schema in URL (for apps that don't support schema in URL)
get_postgres_url_simple() {
    echo "postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
}

get_mongo_url() {
    echo "mongodb://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
}

get_mysql_url() {
    echo "mysql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
}

# Export functions
export -f get_db_recommendation
export -f get_default_db_type
export -f ask_database
export -f ask_custom_db
export -f check_schema_exists
export -f warn_if_schema_exists
export -f fetch_database
export -f fetch_shared_db
export -f show_db_summary
export -f setup_database
export -f setup_shared_db
export -f setup_custom_db
export -f get_postgres_url
export -f get_postgres_url_simple
export -f get_mongo_url
export -f get_mysql_url
