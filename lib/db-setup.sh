#!/bin/bash

# StackPilot - Database Setup Helper
# Used by installation scripts to configure the database.
# Author: Paweł (Lazy Engineer)
#
# FLOW with CLI:
#   1. parse_args() + load_defaults()  - from cli-parser.sh
#   2. ask_database()    - checks flags, only asks when missing
#   3. fetch_database()  - sets up bundled DB or validates custom credentials
#
# CLI flags:
#   --db-source=bundled|custom
#   --db-host=HOST --db-port=PORT --db-name=NAME
#   --db-schema=SCHEMA --db-user=USER --db-pass=PASS
#
# Available variables after calling:
#   $DB_HOST, $DB_PORT, $DB_NAME, $DB_SCHEMA, $DB_USER, $DB_PASS, $DB_SOURCE
#   $BUNDLED_DB_TYPE (postgres|mysql) - set when DB_SOURCE=bundled

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
export BUNDLED_DB_TYPE="${BUNDLED_DB_TYPE:-}"

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

    # If DB_SOURCE already set from CLI
    if [ -n "$DB_SOURCE" ]; then
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

        # Validation: bundled is handled later in fetch_database
        if [ "$DB_SOURCE" = "bundled" ]; then
            BUNDLED_DB_TYPE="$DB_TYPE"
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

    echo ""
    echo "Where should the database be hosted?"
    echo ""

    echo "  1) 📦 Bundled database (recommended)"
    echo "     PostgreSQL/MySQL container alongside the app — zero config"
    echo ""

    echo "  2) 🔧 External database"
    echo "     You will provide your own connection details"
    echo ""

    local DEFAULT_CHOICE="1"

    read -p "Choose option [1-2, default $DEFAULT_CHOICE]: " DB_CHOICE
    DB_CHOICE="${DB_CHOICE:-$DEFAULT_CHOICE}"

    case $DB_CHOICE in
        1)
            export DB_SOURCE="bundled"
            BUNDLED_DB_TYPE="$DB_TYPE"
            echo ""
            echo -e "${GREEN}✅ Selected: bundled database ($DB_TYPE in Docker)${NC}"
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
# BUNDLED DATABASE SETUP
# =============================================================================

# Generate credentials and set DB_* variables for a bundled database container.
# The calling script (deploy.sh / install.sh) is responsible for adding the
# corresponding postgres/mysql service to docker-compose.yaml.
#
# Sets: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS, BUNDLED_DB_TYPE
setup_bundled_db() {
    local DB_TYPE="${1:-${BUNDLED_DB_TYPE:-postgres}}"

    BUNDLED_DB_TYPE="$DB_TYPE"

    # Generate random credentials
    DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
    DB_USER="app"
    DB_NAME="appdb"

    if [ "$DB_TYPE" = "postgres" ]; then
        # The container name in docker-compose will be "db" on the internal network
        DB_HOST="db"
        DB_PORT="5432"
    elif [ "$DB_TYPE" = "mysql" ]; then
        DB_HOST="db"
        DB_PORT="3306"
    else
        echo -e "${RED}❌ Bundled DB not supported for type: $DB_TYPE${NC}" >&2
        return 1
    fi

    export DB_HOST DB_PORT DB_NAME DB_USER DB_PASS BUNDLED_DB_TYPE

    echo -e "${GREEN}✅ Bundled $DB_TYPE database configured${NC}"
    echo "   Credentials generated automatically (stored in docker-compose.yaml)"

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
# PHASE 2: Fetching/setting up data (heavy operations)
# =============================================================================

fetch_database() {
    local DB_TYPE="${1:-postgres}"
    local SSH_ALIAS="${2:-${SSH_ALIAS:-vps}}"

    # If custom - data is already available, nothing to do
    if [ "$DB_SOURCE" = "custom" ]; then
        return 0
    fi

    # Bundled - generate credentials and prepare container config
    if [ "$DB_SOURCE" = "bundled" ]; then
        setup_bundled_db "$DB_TYPE"
        return $?
    fi

    echo -e "${RED}❌ Unknown database source: $DB_SOURCE${NC}"
    return 1
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

    # Phase 2: set up bundled or validate custom
    if ! fetch_database "$DB_TYPE" "$SSH_ALIAS"; then
        return 1
    fi

    # Show summary
    show_db_summary

    return 0
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
export -f ask_database
export -f ask_custom_db
export -f setup_bundled_db
export -f check_schema_exists
export -f warn_if_schema_exists
export -f fetch_database
export -f show_db_summary
export -f setup_database
export -f setup_custom_db
export -f get_postgres_url
export -f get_postgres_url_simple
export -f get_mongo_url
export -f get_mysql_url
