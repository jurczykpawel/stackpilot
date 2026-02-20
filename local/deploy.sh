#!/bin/bash

# StackPilot - Remote Deployer
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/deploy.sh APP [--ssh=ALIAS] [--db-source=bundled|custom] [--domain=DOMAIN] [--yes]
#
# Examples:
#   ./local/deploy.sh n8n --ssh=vps                                # interactive
#   ./local/deploy.sh n8n --ssh=vps --db-source=bundled --domain=auto --yes  # automatic
#   ./local/deploy.sh uptime-kuma --domain-type=local --yes        # no domain
#
# FLOW:
#   1. Parse CLI arguments
#   2. User confirmation (skip with --yes)
#   3. GATHER PHASE - questions about DB and domain (skip with CLI)
#   4. "Now sit back and relax - working..."
#   5. EXECUTION PHASE - API calls, Docker, installation
#   6. Domain configuration (AFTER service is running!)
#   7. Summary

set -e

# Find repo directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load libraries
source "$REPO_ROOT/lib/cli-parser.sh"
source "$REPO_ROOT/lib/db-setup.sh"
source "$REPO_ROOT/lib/domain-setup.sh"
source "$REPO_ROOT/lib/gateflow-setup.sh" 2>/dev/null || true  # Optional for GateFlow
source "$REPO_ROOT/lib/port-utils.sh"

# =============================================================================
# CUSTOM HELP
# =============================================================================

show_deploy_help() {
    cat <<EOF
StackPilot - Deploy

Usage:
  ./local/deploy.sh APP [options]

Arguments:
  APP                  Application name (e.g. n8n, uptime-kuma) or path to script

SSH Options:
  --ssh=ALIAS          SSH alias from ~/.ssh/config (default: vps)

Database Options:
  --db-source=TYPE     Database source: bundled (Docker container) or custom
  --db-host=HOST       Database host
  --db-port=PORT       Database port (default: 5432)
  --db-name=NAME       Database name
  --db-schema=SCHEMA   PostgreSQL schema (default: public)
  --db-user=USER       Database user
  --db-pass=PASS       Database password

Domain Options:
  --domain=DOMAIN      Application domain (e.g. app.example.com)
  --domain-type=TYPE   Type: cloudflare, caddy, local

Modes:
  --yes, -y            Skip all confirmations
  --dry-run            Show what would be executed without running
  --update             Update existing application (instead of installing)
  --restart            Restart without updating (e.g. after .env change) - used with --update
  --build-file=PATH    Use local tar.gz file (for --update, when repo is private)
  --help, -h           Show this help

Examples:
  # Interactive (prompts for missing data)
  ./local/deploy.sh n8n --ssh=vps

  # Automatic with Caddy (point A record to server IP first)
  ./local/deploy.sh uptime-kuma --ssh=vps --domain-type=caddy --domain=kuma.example.com --yes

  # Automatic with Cloudflare
  ./local/deploy.sh n8n --ssh=vps \\
    --db-source=custom --db-host=psql.example.com \\
    --db-name=n8n --db-user=user --db-pass=secret \\
    --domain-type=cloudflare --domain=n8n.example.com --yes

  # Local only (no domain)
  ./local/deploy.sh dockge --ssh=vps --domain-type=local --yes

  # Dry-run (preview without executing)
  ./local/deploy.sh n8n --ssh=vps --dry-run

  # Update existing application
  ./local/deploy.sh gateflow --ssh=vps --update

  # Update from local file (when repo is private)
  ./local/deploy.sh gateflow --ssh=vps --update --build-file=~/Downloads/gateflow-build.tar.gz

  # Restart without updating (e.g. after .env change)
  ./local/deploy.sh gateflow --ssh=vps --update --restart

EOF
}

# Override show_help from cli-parser
show_help() {
    show_deploy_help
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

load_defaults
parse_args "$@"

# First positional argument = APP
SCRIPT_PATH="${POSITIONAL_ARGS[0]:-}"

if [ -z "$SCRIPT_PATH" ]; then
    echo "Error: No application name provided."
    echo ""
    show_deploy_help
    exit 1
fi

# SSH_ALIAS from --ssh or default
SSH_ALIAS="${SSH_ALIAS:-vps}"

# =============================================================================
# SSH CONNECTION CHECK
# =============================================================================

if ! is_on_server; then
    # Check if SSH alias is configured (ssh -G parses config without connecting)
    _SSH_RESOLVED_HOST=$(ssh -G "$SSH_ALIAS" 2>/dev/null | awk '/^hostname / {print $2}')

    if [ -z "$_SSH_RESOLVED_HOST" ] || [ "$_SSH_RESOLVED_HOST" = "$SSH_ALIAS" ]; then
        # Alias is not configured in ~/.ssh/config
        echo ""
        echo -e "${RED}❌ SSH alias '$SSH_ALIAS' is not configured${NC}"
        echo ""
        echo "   You need the server connection details: host, port, and password."
        echo ""

        SETUP_SCRIPT="$REPO_ROOT/local/setup-ssh.sh"
        if [[ "$IS_GITBASH" == "true" ]] || [[ "$YES_MODE" == "true" ]]; then
            # Windows (Git Bash) or --yes mode — show instructions
            echo "   Run SSH configuration:"
            echo -e "   ${BLUE}bash local/setup-ssh.sh${NC}"
            exit 1
        elif [ -f "$SETUP_SCRIPT" ]; then
            # macOS/Linux — offer automatic setup
            if confirm "   Configure SSH connection now?"; then
                echo ""
                bash "$SETUP_SCRIPT"
                # After configuration, check again
                if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_ALIAS" "echo ok" &>/dev/null; then
                    echo ""
                    echo -e "${RED}❌ Connection still not working. Check the details and try again.${NC}"
                    exit 1
                fi
            else
                exit 1
            fi
        else
            echo "   Configure SSH:"
            echo -e "   ${BLUE}bash <(curl -s https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/local/setup-ssh.sh)${NC}"
            exit 1
        fi
    else
        # Alias configured — check if connection works
        echo -n "🔗 Checking SSH connection ($SSH_ALIAS)... "
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_ALIAS" "echo ok" &>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
            echo ""
            echo -e "${RED}❌ Cannot connect to server '$SSH_ALIAS' ($_SSH_RESOLVED_HOST)${NC}"
            echo ""
            echo "   Possible causes:"
            echo "   - Server is down or not responding"
            echo "   - SSH key is not authorized on the server"
            echo "   - Invalid host or port in ~/.ssh/config"
            echo ""
            echo "   Diagnostics:"
            echo -e "   ${BLUE}ssh -v $SSH_ALIAS${NC}"
            echo ""
            echo "   Reconfigure:"
            echo -e "   ${BLUE}bash local/setup-ssh.sh${NC}"
            exit 1
        fi
    fi
fi

# =============================================================================
# LOAD SAVED CONFIGURATION (for GateFlow)
# =============================================================================

GATEFLOW_CONFIG="$HOME/.config/gateflow/deploy-config.env"
if [ -f "$GATEFLOW_CONFIG" ] && [[ "$SCRIPT_PATH" == "gateflow" ]]; then
    # Preserve CLI values (they take priority over config)
    CLI_SSH_ALIAS="$SSH_ALIAS"
    CLI_DOMAIN="$DOMAIN"
    CLI_DOMAIN_TYPE="$DOMAIN_TYPE"
    CLI_SUPABASE_PROJECT="$SUPABASE_PROJECT"

    # Load config
    source "$GATEFLOW_CONFIG"

    # Restore CLI values if provided (CLI > config)
    [ -n "$CLI_SSH_ALIAS" ] && SSH_ALIAS="$CLI_SSH_ALIAS"
    [ -n "$CLI_DOMAIN" ] && DOMAIN="$CLI_DOMAIN"
    [ -n "$CLI_DOMAIN_TYPE" ] && DOMAIN_TYPE="$CLI_DOMAIN_TYPE"
    [ -n "$CLI_SUPABASE_PROJECT" ] && SUPABASE_PROJECT="$CLI_SUPABASE_PROJECT"

    if [ "$YES_MODE" = true ]; then
        # --yes mode: use saved configuration (with CLI overrides)
        echo "📂 Loading saved GateFlow configuration (--yes mode)..."

        # Supabase
        [ -n "$SUPABASE_URL" ] && export SUPABASE_URL
        [ -n "$PROJECT_REF" ] && export PROJECT_REF
        [ -n "$SUPABASE_ANON_KEY" ] && export SUPABASE_ANON_KEY
        [ -n "$SUPABASE_SERVICE_KEY" ] && export SUPABASE_SERVICE_KEY

        # Stripe
        [ -n "$STRIPE_PK" ] && export STRIPE_PK
        [ -n "$STRIPE_SK" ] && export STRIPE_SK
        [ -n "$STRIPE_WEBHOOK_SECRET" ] && export STRIPE_WEBHOOK_SECRET

        # Turnstile
        [ -n "$CLOUDFLARE_TURNSTILE_SITE_KEY" ] && export CLOUDFLARE_TURNSTILE_SITE_KEY
        [ -n "$CLOUDFLARE_TURNSTILE_SECRET_KEY" ] && export CLOUDFLARE_TURNSTILE_SECRET_KEY

        echo "   ✅ Configuration loaded"
    else
        # Interactive mode: ask about everything, only keep Supabase token
        echo "📂 Interactive mode - will ask about configuration"

        # Clear everything except token (so you don't have to log in again)
        unset SUPABASE_URL PROJECT_REF SUPABASE_ANON_KEY SUPABASE_SERVICE_KEY
        unset STRIPE_PK STRIPE_SK STRIPE_WEBHOOK_SECRET
        unset CLOUDFLARE_TURNSTILE_SITE_KEY CLOUDFLARE_TURNSTILE_SECRET_KEY
        unset DOMAIN DOMAIN_TYPE
    fi
fi

# =============================================================================
# UPDATE MODE (--update)
# =============================================================================

if [ "$UPDATE_MODE" = true ]; then
    APP_NAME="$SCRIPT_PATH"

    # Check if the application has an update.sh script
    UPDATE_SCRIPT="$REPO_ROOT/apps/$APP_NAME/update.sh"
    if [ ! -f "$UPDATE_SCRIPT" ]; then
        echo -e "${RED}❌ Application '$APP_NAME' does not have an update script${NC}"
        echo "   Missing: apps/$APP_NAME/update.sh"
        exit 1
    fi

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  🔄 UPDATE: $APP_NAME"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Server: $SSH_ALIAS"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    if ! confirm "Update $APP_NAME on server $SSH_ALIAS?"; then
        echo "Cancelled."
        exit 0
    fi

    echo ""
    echo "🚀 Starting update..."

    # Copy script to server
    REMOTE_SCRIPT="/tmp/mikrus-update-$$.sh"
    server_copy "$UPDATE_SCRIPT" "$REMOTE_SCRIPT"

    # If we have a local build file, copy it to the server
    REMOTE_BUILD_FILE=""
    if [ -n "$BUILD_FILE" ]; then
        # Expand ~ to full path
        BUILD_FILE="${BUILD_FILE/#\~/$HOME}"

        if [ ! -f "$BUILD_FILE" ]; then
            echo -e "${RED}❌ File does not exist: $BUILD_FILE${NC}"
            exit 1
        fi

        echo "📤 Copying build file to server..."
        REMOTE_BUILD_FILE="/tmp/gateflow-build-$$.tar.gz"
        server_copy "$BUILD_FILE" "$REMOTE_BUILD_FILE"
        echo "   ✅ Copied"
    fi

    # Pass environment variables
    ENV_VARS="SKIP_MIGRATIONS=1"  # Migrations will be run locally via API
    if [ -n "$REMOTE_BUILD_FILE" ]; then
        ENV_VARS="$ENV_VARS BUILD_FILE='$REMOTE_BUILD_FILE'"
    fi

    # For multi-instance: pass instance name (from --instance or --domain)
    if [ -n "$INSTANCE" ]; then
        ENV_VARS="$ENV_VARS INSTANCE='$INSTANCE'"
    elif [ -n "$DOMAIN" ]; then
        # Derive instance from domain
        UPDATE_INSTANCE="${DOMAIN%%.*}"
        ENV_VARS="$ENV_VARS INSTANCE='$UPDATE_INSTANCE'"
    fi

    # Prepare arguments for update.sh
    UPDATE_SCRIPT_ARGS=""
    if [ "$RESTART_ONLY" = true ]; then
        UPDATE_SCRIPT_ARGS="--restart"
    fi

    # Run script and clean up
    CLEANUP_CMD="rm -f '$REMOTE_SCRIPT'"
    if [ -n "$REMOTE_BUILD_FILE" ]; then
        CLEANUP_CMD="$CLEANUP_CMD '$REMOTE_BUILD_FILE'"
    fi

    if server_exec_tty "export $ENV_VARS; bash '$REMOTE_SCRIPT' $UPDATE_SCRIPT_ARGS; EXIT_CODE=\$?; $CLEANUP_CMD; exit \$EXIT_CODE"; then
        echo ""
        if [ "$RESTART_ONLY" = true ]; then
            echo -e "${GREEN}✅ GateFlow restarted!${NC}"
        else
            echo -e "${GREEN}✅ Files updated${NC}"
        fi
    else
        echo ""
        echo -e "${RED}❌ Update failed${NC}"
        exit 1
    fi

    # For GateFlow - run migrations via API (locally) - only in update mode, not restart
    if [ "$APP_NAME" = "gateflow" ] && [ "$RESTART_ONLY" = false ]; then
        echo ""
        echo "🗄️  Updating database..."

        if [ -f "$REPO_ROOT/local/setup-supabase-migrations.sh" ]; then
            SSH_ALIAS="$SSH_ALIAS" "$REPO_ROOT/local/setup-supabase-migrations.sh" || true
        fi
    fi

    echo ""
    if [ "$RESTART_ONLY" = true ]; then
        echo -e "${GREEN}✅ Restart completed!${NC}"
    else
        echo -e "${GREEN}✅ Update completed!${NC}"
    fi

    exit 0
fi

# =============================================================================
# RESOLVE APP/SCRIPT PATH
# =============================================================================

APP_NAME=""
if [ -f "$REPO_ROOT/apps/$SCRIPT_PATH/install.sh" ]; then
    echo "💡 Detected application: '$SCRIPT_PATH'"
    APP_NAME="$SCRIPT_PATH"
    SCRIPT_PATH="$REPO_ROOT/apps/$SCRIPT_PATH/install.sh"
elif [ -f "$SCRIPT_PATH" ]; then
    :  # Direct file exists
elif [ -f "$REPO_ROOT/$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$REPO_ROOT/$SCRIPT_PATH"
else
    echo "Error: Script or application '$SCRIPT_PATH' not found."
    echo "   Searched:"
    echo "   - apps/$SCRIPT_PATH/install.sh"
    echo "   - $SCRIPT_PATH"
    exit 1
fi

# =============================================================================
# CONFIRMATION
# =============================================================================

REMOTE_HOST=$(server_hostname)
REMOTE_USER=$(server_user)
SCRIPT_DISPLAY="${SCRIPT_PATH#$REPO_ROOT/}"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
if is_on_server; then
echo "║  ⚠️   WARNING: INSTALLING ON THIS SERVER!                        ║"
else
echo "║  ⚠️   WARNING: INSTALLING ON REMOTE SERVER!                    ║"
fi
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  Server:  $REMOTE_USER@$REMOTE_HOST"
echo "║  Script:  $SCRIPT_DISPLAY"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Warning for Git Bash + MinTTY (before interactive prompts)
warn_gitbash_mintty

if ! confirm "Are you sure you want to run this script on the REMOTE server?"; then
    echo "Cancelled."
    exit 1
fi

# =============================================================================
# PHASE 0: SERVER RESOURCE CHECK
# =============================================================================

# Detect RAM requirements from docker-compose (memory limit)
REQUIRED_RAM=256  # default
if grep -q "memory:" "$SCRIPT_PATH" 2>/dev/null; then
    # Portable version (without grep -P which doesn't work on macOS)
    MEM_LIMIT=$(grep "memory:" "$SCRIPT_PATH" | sed -E 's/[^0-9]*([0-9]+).*/\1/' | head -1)
    if [ -n "$MEM_LIMIT" ]; then
        REQUIRED_RAM=$MEM_LIMIT
    fi
fi

# Detect Docker image size
# 1. Try Docker Hub API (dynamically)
# 2. Fallback to IMAGE_SIZE_MB from script header
REQUIRED_DISK=500  # default 500MB
IMAGE_SIZE=""
IMAGE_SIZE_SOURCE=""

# Extract image name from docker-compose in the script
DOCKER_IMAGE=$(grep -E "^[[:space:]]*image:" "$SCRIPT_PATH" 2>/dev/null | head -1 | awk -F'image:' '{gsub(/^[[:space:]]*|[[:space:]]*$/,"",$2); print $2}')

if [ -n "$DOCKER_IMAGE" ]; then
    # Only Docker Hub supports our API query (not ghcr.io, quay.io, etc.)
    if [[ "$DOCKER_IMAGE" != *"ghcr.io"* ]] && [[ "$DOCKER_IMAGE" != *"quay.io"* ]] && [[ "$DOCKER_IMAGE" != *"gcr.io"* ]]; then
        # Parse image name: owner/repo:tag or library/repo:tag
        if [[ "$DOCKER_IMAGE" == *"/"* ]]; then
            REPO_OWNER=$(echo "$DOCKER_IMAGE" | cut -d'/' -f1)
            REPO_NAME=$(echo "$DOCKER_IMAGE" | cut -d'/' -f2 | cut -d':' -f1)
            TAG=$(echo "$DOCKER_IMAGE" | grep -o ':[^:]*$' | tr -d ':')
            [ -z "$TAG" ] && TAG="latest"
        else
            # Official image (e.g., redis:alpine)
            REPO_OWNER="library"
            REPO_NAME=$(echo "$DOCKER_IMAGE" | cut -d':' -f1)
            TAG=$(echo "$DOCKER_IMAGE" | grep -o ':[^:]*$' | tr -d ':')
            [ -z "$TAG" ] && TAG="latest"
        fi

        # Try Docker Hub API (timeout 5s)
        API_URL="https://hub.docker.com/v2/repositories/${REPO_OWNER}/${REPO_NAME}/tags/${TAG}"
        COMPRESSED_SIZE=$(curl -sf --max-time 5 "$API_URL" 2>/dev/null | grep -o '"full_size":[0-9]*' | grep -o '[0-9]*')

        if [ -n "$COMPRESSED_SIZE" ] && [ "$COMPRESSED_SIZE" -gt 0 ]; then
            # Compressed * 2.5 ≈ uncompressed size on disk
            IMAGE_SIZE=$((COMPRESSED_SIZE / 1024 / 1024 * 25 / 10))
            IMAGE_SIZE_SOURCE="Docker Hub API"
        fi
    fi
fi

# Fallback to hardcoded IMAGE_SIZE_MB
if [ -z "$IMAGE_SIZE" ]; then
    IMAGE_SIZE=$(grep "^# IMAGE_SIZE_MB=" "$SCRIPT_PATH" 2>/dev/null | sed -E 's/.*IMAGE_SIZE_MB=([0-9]+).*/\1/' | head -1)
    [ -n "$IMAGE_SIZE" ] && IMAGE_SIZE_SOURCE="script"
fi

if [ -n "$IMAGE_SIZE" ]; then
    # Add 20% margin for temp files during download
    REQUIRED_DISK=$((IMAGE_SIZE + IMAGE_SIZE / 5))
fi

# Check server resources
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  📊 Checking server resources...                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"

RESOURCES=$(server_exec_timeout 10 "free -m | awk '/^Mem:/ {print \$7}'; df -m / | awk 'NR==2 {print \$4}'; free -m | awk '/^Mem:/ {print \$2}'" 2>/dev/null)
AVAILABLE_RAM=$(echo "$RESOURCES" | sed -n '1p')
AVAILABLE_DISK=$(echo "$RESOURCES" | sed -n '2p')
TOTAL_RAM=$(echo "$RESOURCES" | sed -n '3p')

if [ -n "$AVAILABLE_RAM" ] && [ -n "$AVAILABLE_DISK" ]; then
    echo ""
    echo -n "   RAM: ${AVAILABLE_RAM}MB available (of ${TOTAL_RAM}MB)"
    if [ "$AVAILABLE_RAM" -lt "$REQUIRED_RAM" ]; then
        echo -e " ${RED}✗ required: ${REQUIRED_RAM}MB${NC}"
        if [ "$YES_MODE" != "true" ]; then
            echo ""
            echo -e "${RED}   ❌ Not enough RAM! Installation may freeze the server.${NC}"
            if ! confirm "   Continue anyway?"; then
                echo "Cancelled."
                exit 1
            fi
        fi
    elif [ "$AVAILABLE_RAM" -lt $((REQUIRED_RAM + 100)) ]; then
        echo -e " ${YELLOW}⚠ tight${NC}"
    else
        echo -e " ${GREEN}✓${NC}"
    fi

    echo -n "   Disk: ${AVAILABLE_DISK}MB free"
    if [ "$AVAILABLE_DISK" -lt "$REQUIRED_DISK" ]; then
        echo -e " ${RED}✗ required: ~${REQUIRED_DISK}MB${NC}"
        echo ""
        echo -e "${RED}   ❌ Not enough disk space!${NC}"
        if [ -n "$IMAGE_SIZE_SOURCE" ]; then
            echo -e "${RED}   Docker image: ~${IMAGE_SIZE}MB (${IMAGE_SIZE_SOURCE}) + temp files${NC}"
        else
            echo -e "${RED}   Docker image will use ~500MB + temp files.${NC}"
        fi
        if [ "$YES_MODE" == "true" ]; then
            echo -e "${RED}   Aborting installation (--yes mode).${NC}"
            exit 1
        fi
        if ! confirm "   Continue anyway?"; then
            echo "Cancelled."
            exit 1
        fi
    elif [ "$AVAILABLE_DISK" -lt $((REQUIRED_DISK + 500)) ]; then
        echo -e " ${YELLOW}⚠ low space (need ~${REQUIRED_DISK}MB)${NC}"
    else
        echo -e " ${GREEN}✓${NC}"
    fi

    # Warning for heavy applications on low RAM
    if [ "$REQUIRED_RAM" -ge 400 ] && [ "$TOTAL_RAM" -lt 2000 ]; then
        echo ""
        echo -e "   ${YELLOW}⚠ This application requires a lot of RAM (${REQUIRED_RAM}MB).${NC}"
        echo -e "   ${YELLOW}  Recommended: a VPS plan with 2GB+ RAM${NC}"
    fi
else
    echo -e "   ${YELLOW}⚠ Could not check resources${NC}"
fi

# =============================================================================
# PHASE 0.5: PORT CHECK
# =============================================================================

# Get default port from install.sh
# Handles: PORT=3000 and PORT=${PORT:-3000}
DEFAULT_PORT=$(grep -E "^PORT=" "$SCRIPT_PATH" 2>/dev/null | head -1 | sed -E 's/.*[=:-]([0-9]+).*/\1/')
PORT_OVERRIDE=""

if [ -n "$DEFAULT_PORT" ]; then
    # Check if port is in use on the server
    PORT_IN_USE=$(server_exec_timeout 5 "ss -tlnp 2>/dev/null | grep -q ':${DEFAULT_PORT} ' && echo 'yes' || echo 'no'" 2>/dev/null)

    if [ "$PORT_IN_USE" == "yes" ]; then
        echo ""
        echo -e "   ${YELLOW}⚠ Port $DEFAULT_PORT is in use!${NC}"

        # Single SSH call → port list, search in memory (no retry limit)
        PORT_OVERRIDE=$(find_free_port_remote "$SSH_ALIAS" $((DEFAULT_PORT + 1)))
        if [ -n "$PORT_OVERRIDE" ]; then
            echo -e "   ${GREEN}✓ Using port $PORT_OVERRIDE instead of $DEFAULT_PORT${NC}"
        fi
    fi
fi

# =============================================================================
# PHASE 1: GATHERING INFORMATION (no API/heavy operations)
# =============================================================================

# Variables to pass
DB_ENV_VARS=""
DB_TYPE=""
NEEDS_DB=false
NEEDS_DOMAIN=false
APP_PORT=""

# Check if application requires a database
# WordPress with WP_DB_MODE=sqlite does not need MySQL
if grep -qiE "DB_HOST|DATABASE_URL" "$SCRIPT_PATH" 2>/dev/null; then
    if [ "$APP_NAME" = "wordpress" ] && [ "$WP_DB_MODE" = "sqlite" ]; then
        echo ""
        echo -e "${GREEN}✅ WordPress in SQLite mode — MySQL database is not required${NC}"
    else
        NEEDS_DB=true

        # Detect database type
        if grep -qi "mysql" "$SCRIPT_PATH"; then
            DB_TYPE="mysql"
        elif grep -qi "mongo" "$SCRIPT_PATH"; then
            DB_TYPE="mongo"
        else
            DB_TYPE="postgres"
        fi

        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  🗄️  This application requires a database ($DB_TYPE)             ║"
        echo "╚════════════════════════════════════════════════════════════════╝"

        if ! ask_database "$DB_TYPE" "$APP_NAME"; then
            echo "Error: Database configuration failed."
            exit 1
        fi
    fi
fi

# Check if this is an app and requires a domain
if [[ "$SCRIPT_DISPLAY" == apps/* ]]; then
    APP_PORT=$(grep -E "^PORT=" "$SCRIPT_PATH" | head -1 | sed -E 's/.*[=:-]([0-9]+).*/\1/')

    # Also check if script requires DOMAIN (e.g. static sites without Docker)
    REQUIRES_DOMAIN_UPFRONT=false
    if grep -q 'if \[ -z "\$DOMAIN" \]' "$SCRIPT_PATH" 2>/dev/null; then
        REQUIRES_DOMAIN_UPFRONT=true
        APP_PORT="${APP_PORT:-443}"  # Static sites use HTTPS via Caddy
    fi

    if [ -n "$APP_PORT" ] || [ "$REQUIRES_DOMAIN_UPFRONT" = true ]; then
        NEEDS_DOMAIN=true

        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  🌐 Domain configuration for: $APP_NAME                         ║"
        echo "╚════════════════════════════════════════════════════════════════╝"

        if ! ask_domain "$APP_NAME" "$APP_PORT" "$SSH_ALIAS"; then
            echo ""
            echo "Error: Domain configuration failed."
            exit 1
        fi
    fi
fi

# =============================================================================
# PHASE 1.5: GATEFLOW CONFIGURATION (Supabase questions)
# =============================================================================

# GateFlow variables
GATEFLOW_TURNSTILE_SECRET=""
SETUP_TURNSTILE_LATER=false
TURNSTILE_OFFERED=false
GATEFLOW_STRIPE_CONFIGURED=false

if [ "$APP_NAME" = "gateflow" ]; then
    # 1. Collect Supabase configuration (token + project selection)
    # Fetch keys if:
    # - We don't have SUPABASE_URL, OR
    # - --supabase-project was provided and differs from current PROJECT_REF
    NEED_SUPABASE_FETCH=false
    if [ -z "$SUPABASE_URL" ]; then
        NEED_SUPABASE_FETCH=true
    elif [ -n "$SUPABASE_PROJECT" ] && [ "$SUPABASE_PROJECT" != "$PROJECT_REF" ]; then
        # Different project than saved - need to fetch new keys
        NEED_SUPABASE_FETCH=true
        echo "📦 Changing Supabase project: $PROJECT_REF → $SUPABASE_PROJECT"
    fi

    if [ "$NEED_SUPABASE_FETCH" = true ]; then
        if [ -n "$SUPABASE_PROJECT" ]; then
            # --supabase-project provided - fetch keys automatically
            echo ""
            echo "📦 Supabase configuration (project: $SUPABASE_PROJECT)"

            # Make sure we have a token
            if ! check_saved_supabase_token; then
                if ! supabase_manual_token_flow; then
                    echo "❌ Missing Supabase token"
                    exit 1
                fi
                save_supabase_token "$SUPABASE_TOKEN"
            fi

            if ! fetch_supabase_keys_by_ref "$SUPABASE_PROJECT"; then
                echo "❌ Failed to fetch keys for project: $SUPABASE_PROJECT"
                exit 1
            fi
        else
            # Interactive project selection
            if ! gateflow_collect_config "$DOMAIN"; then
                echo "❌ Supabase configuration failed"
                exit 1
            fi
        fi
    fi

    # 2. Collect Stripe configuration (local prompt)
    gateflow_collect_stripe_config
fi

# Turnstile for GateFlow - CAPTCHA configuration prompt
# Turnstile works on any domain (not just Cloudflare DNS), only requires a Cloudflare account
# Skip only for: local (dev) or missing domain
if [ "$APP_NAME" = "gateflow" ] && [ "$DOMAIN_TYPE" != "local" ] && [ -n "$DOMAIN" ]; then
    TURNSTILE_OFFERED=true
    echo ""
    echo "🔒 Turnstile Configuration (CAPTCHA)"
    echo ""

    if [ "$YES_MODE" = true ]; then
        # In --yes mode check if we have saved keys
        KEYS_FILE="$HOME/.config/cloudflare/turnstile_keys_$DOMAIN"
        if [ -f "$KEYS_FILE" ]; then
            source "$KEYS_FILE"
            if [ -n "$CLOUDFLARE_TURNSTILE_SECRET_KEY" ]; then
                GATEFLOW_TURNSTILE_SECRET="$CLOUDFLARE_TURNSTILE_SECRET_KEY"
                echo "   ✅ Using saved Turnstile keys"
            fi
        fi
        if [ -z "$GATEFLOW_TURNSTILE_SECRET" ]; then
            echo -e "${YELLOW}   ⚠️  No saved Turnstile keys${NC}"
            echo "   Configure after installation: ./local/setup-turnstile.sh $DOMAIN $SSH_ALIAS"
            SETUP_TURNSTILE_LATER=true
        fi
    else
        # Interactive mode - ask
        read -p "Configure Turnstile now? [Y/n]: " SETUP_TURNSTILE
        if [[ ! "$SETUP_TURNSTILE" =~ ^[Nn]$ ]]; then
            if [ -f "$REPO_ROOT/local/setup-turnstile.sh" ]; then
                "$REPO_ROOT/local/setup-turnstile.sh" "$DOMAIN"

                # Read keys from saved file
                KEYS_FILE="$HOME/.config/cloudflare/turnstile_keys_$DOMAIN"
                if [ -f "$KEYS_FILE" ]; then
                    source "$KEYS_FILE"
                    if [ -n "$CLOUDFLARE_TURNSTILE_SECRET_KEY" ]; then
                        GATEFLOW_TURNSTILE_SECRET="$CLOUDFLARE_TURNSTILE_SECRET_KEY"
                        EXTRA_ENV="$EXTRA_ENV CLOUDFLARE_TURNSTILE_SITE_KEY='$CLOUDFLARE_TURNSTILE_SITE_KEY' CLOUDFLARE_TURNSTILE_SECRET_KEY='$CLOUDFLARE_TURNSTILE_SECRET_KEY'"
                        echo -e "${GREEN}✅ Turnstile keys will be passed to the installation${NC}"
                    fi
                fi
            else
                echo -e "${YELLOW}⚠️  Missing setup-turnstile.sh script${NC}"
            fi
        else
            echo ""
            echo "⏭️  Skipped. You can configure later:"
            echo "   ./local/setup-turnstile.sh $DOMAIN $SSH_ALIAS"
            SETUP_TURNSTILE_LATER=true
        fi
    fi
    echo ""
fi

# =============================================================================
# PHASE 2: EXECUTION (heavy operations)
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  ☕ Now sit back and relax - working...                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Set up database (bundled generates credentials, custom already has them)
if [ "$NEEDS_DB" = true ]; then
    if ! fetch_database "$DB_TYPE" "$SSH_ALIAS"; then
        echo "Error: Failed to set up database."
        exit 1
    fi

    # Check if schema already exists (warning for user) - only for custom/external DBs
    if [ "$DB_TYPE" = "postgres" ] && [ "$DB_SOURCE" = "custom" ]; then
        if ! warn_if_schema_exists "$SSH_ALIAS" "$APP_NAME"; then
            echo "Installation cancelled by user."
            exit 1
        fi
    fi

    # Escape single quotes in DB_PASS (prevent shell injection)
    ESCAPED_DB_PASS="${DB_PASS//\'/\'\\\'\'}"

    # Prepare environment variables
    DB_ENV_VARS="DB_SOURCE='$DB_SOURCE' DB_HOST='$DB_HOST' DB_PORT='$DB_PORT' DB_NAME='$DB_NAME' DB_SCHEMA='$DB_SCHEMA' DB_USER='$DB_USER' DB_PASS='$ESCAPED_DB_PASS'"
    [ -n "$BUNDLED_DB_TYPE" ] && DB_ENV_VARS="$DB_ENV_VARS BUNDLED_DB_TYPE='$BUNDLED_DB_TYPE'"

    echo ""
    echo "📋 Database ($DB_SOURCE):"
    echo "   Host: $DB_HOST"
    echo "   Database: $DB_NAME"
    if [ -n "$DB_SCHEMA" ] && [ "$DB_SCHEMA" != "public" ]; then
        echo "   Schema: $DB_SCHEMA"
    fi
    echo ""
fi

# Prepare DOMAIN variable for passing
# Always pass domain when available — even in local mode.
# install.sh uses domain for instance naming (e.g. WordPress multi-instance).
DOMAIN_ENV=""
if [ "$NEEDS_DOMAIN" = true ] && [ -n "$DOMAIN" ]; then
    DOMAIN_ENV="DOMAIN='$DOMAIN'"
fi

# Prepare PORT variable for passing (if overridden)
PORT_ENV=""
if [ -n "$PORT_OVERRIDE" ]; then
    PORT_ENV="PORT='$PORT_OVERRIDE'"
    # Also update APP_PORT for configure_domain
    APP_PORT="$PORT_OVERRIDE"
fi

# Pass additional environment variables (for special apps like Cap)
EXTRA_ENV=""
[ -n "$USE_LOCAL_MINIO" ] && EXTRA_ENV="$EXTRA_ENV USE_LOCAL_MINIO='$USE_LOCAL_MINIO'"
[ -n "$S3_ENDPOINT" ] && EXTRA_ENV="$EXTRA_ENV S3_ENDPOINT='$S3_ENDPOINT'"
[ -n "$S3_ACCESS_KEY" ] && EXTRA_ENV="$EXTRA_ENV S3_ACCESS_KEY='$S3_ACCESS_KEY'"
[ -n "$S3_SECRET_KEY" ] && EXTRA_ENV="$EXTRA_ENV S3_SECRET_KEY='$S3_SECRET_KEY'"
[ -n "$S3_BUCKET" ] && EXTRA_ENV="$EXTRA_ENV S3_BUCKET='$S3_BUCKET'"
[ -n "$S3_REGION" ] && EXTRA_ENV="$EXTRA_ENV S3_REGION='$S3_REGION'"
[ -n "$S3_PUBLIC_URL" ] && EXTRA_ENV="$EXTRA_ENV S3_PUBLIC_URL='$S3_PUBLIC_URL'"
[ -n "$MYSQL_ROOT_PASS" ] && EXTRA_ENV="$EXTRA_ENV MYSQL_ROOT_PASS='$MYSQL_ROOT_PASS'"
[ -n "$DOMAIN_PUBLIC" ] && EXTRA_ENV="$EXTRA_ENV DOMAIN_PUBLIC='$DOMAIN_PUBLIC'"
[ -n "$DOMAIN_TYPE" ] && EXTRA_ENV="$EXTRA_ENV DOMAIN_TYPE='$DOMAIN_TYPE'"
[ -n "$WP_DB_MODE" ] && EXTRA_ENV="$EXTRA_ENV WP_DB_MODE='$WP_DB_MODE'"

# For GateFlow - add variables to EXTRA_ENV (collected earlier in PHASE 1.5)
if [ "$APP_NAME" = "gateflow" ]; then
    # Supabase
    if [ -n "$SUPABASE_URL" ]; then
        EXTRA_ENV="$EXTRA_ENV SUPABASE_URL='$SUPABASE_URL' SUPABASE_ANON_KEY='$SUPABASE_ANON_KEY' SUPABASE_SERVICE_KEY='$SUPABASE_SERVICE_KEY'"
    fi

    # Stripe (if collected locally)
    if [ -n "$STRIPE_PK" ] && [ -n "$STRIPE_SK" ]; then
        EXTRA_ENV="$EXTRA_ENV STRIPE_PK='$STRIPE_PK' STRIPE_SK='$STRIPE_SK'"
        [ -n "$STRIPE_WEBHOOK_SECRET" ] && EXTRA_ENV="$EXTRA_ENV STRIPE_WEBHOOK_SECRET='$STRIPE_WEBHOOK_SECRET'"
    fi

    # Turnstile (if collected)
    if [ -n "$GATEFLOW_TURNSTILE_SECRET" ]; then
        EXTRA_ENV="$EXTRA_ENV CLOUDFLARE_TURNSTILE_SITE_KEY='$CLOUDFLARE_TURNSTILE_SITE_KEY' CLOUDFLARE_TURNSTILE_SECRET_KEY='$CLOUDFLARE_TURNSTILE_SECRET_KEY'"
    fi
fi

# Dry-run mode
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run] Execution simulation:${NC}"
    if is_on_server; then
        echo "  bash $SCRIPT_PATH"
        echo "  env: DEPLOY_SSH_ALIAS='$SSH_ALIAS' $PORT_ENV $DB_ENV_VARS $DOMAIN_ENV $EXTRA_ENV"
    else
        echo "  scp $SCRIPT_PATH $SSH_ALIAS:/tmp/mikrus-deploy-$$.sh"
        echo "  ssh -t $SSH_ALIAS \"export DEPLOY_SSH_ALIAS='$SSH_ALIAS' $PORT_ENV $DB_ENV_VARS $DOMAIN_ENV $EXTRA_ENV; bash '/tmp/mikrus-deploy-$$.sh'\""
    fi
    echo ""
    echo -e "${BLUE}[dry-run] After installation:${NC}"
    if [ "$NEEDS_DOMAIN" = true ]; then
        echo "  configure_domain $APP_PORT $SSH_ALIAS"
    fi
    echo ""
    echo -e "${GREEN}[dry-run] Simulation completed.${NC}"
    exit 0
fi

# Upload script to server and execute
echo "🚀 Starting installation on server..."
echo ""

# =============================================================================
# BUILD FILE (for GateFlow from private repo)
# =============================================================================

REMOTE_BUILD_FILE=""
if [ -n "$BUILD_FILE" ]; then
    # Expand ~ to full path
    BUILD_FILE="${BUILD_FILE/#\~/$HOME}"

    if [ ! -f "$BUILD_FILE" ]; then
        echo -e "${RED}❌ File does not exist: $BUILD_FILE${NC}"
        exit 1
    fi

    echo "📦 Uploading installation file to server..."
    REMOTE_BUILD_FILE="/tmp/gateflow-build-$$.tar.gz"
    server_copy "$BUILD_FILE" "$REMOTE_BUILD_FILE"
    echo "   ✅ File uploaded"

    EXTRA_ENV="$EXTRA_ENV BUILD_FILE='$REMOTE_BUILD_FILE'"
fi

DEPLOY_SUCCESS=false
if is_on_server; then
    # On server: run script directly (no scp/cleanup)
    if (export DEPLOY_SSH_ALIAS="$SSH_ALIAS" SSH_ALIAS="$SSH_ALIAS" YES_MODE="$YES_MODE" $PORT_ENV $DB_ENV_VARS $DOMAIN_ENV $EXTRA_ENV; bash "$SCRIPT_PATH"); then
        DEPLOY_SUCCESS=true
    fi
    [ -n "$REMOTE_BUILD_FILE" ] && rm -f "$REMOTE_BUILD_FILE"
else
    REMOTE_SCRIPT="/tmp/mikrus-deploy-$$.sh"
    scp -q "$SCRIPT_PATH" "$SSH_ALIAS:$REMOTE_SCRIPT"

    # Cleanup remote build file after install
    CLEANUP_CMD=""
    if [ -n "$REMOTE_BUILD_FILE" ]; then
        CLEANUP_CMD="rm -f '$REMOTE_BUILD_FILE';"
    fi

    if ssh -t "$SSH_ALIAS" "export DEPLOY_SSH_ALIAS='$SSH_ALIAS' SSH_ALIAS='$SSH_ALIAS' YES_MODE='$YES_MODE' $PORT_ENV $DB_ENV_VARS $DOMAIN_ENV $EXTRA_ENV; bash '$REMOTE_SCRIPT'; EXIT_CODE=\$?; rm -f '$REMOTE_SCRIPT'; $CLEANUP_CMD exit \$EXIT_CODE"; then
        DEPLOY_SUCCESS=true
    fi
fi

if [ "$DEPLOY_SUCCESS" = true ]; then
    : # Success - continue to database preparation and domain configuration
else
    echo ""
    echo -e "${RED}❌ Installation FAILED! Check errors above.${NC}"
    exit 1
fi

# =============================================================================
# GATEFLOW POST-INSTALLATION CONFIGURATION
# =============================================================================

if [ "$APP_NAME" = "gateflow" ]; then
    # 1. Database migrations
    echo ""
    echo "🗄️  Preparing database..."

    if [ -f "$REPO_ROOT/local/setup-supabase-migrations.sh" ]; then
        SSH_ALIAS="$SSH_ALIAS" PROJECT_REF="$PROJECT_REF" SUPABASE_URL="$SUPABASE_URL" "$REPO_ROOT/local/setup-supabase-migrations.sh" || {
            echo -e "${YELLOW}⚠️  Failed to prepare database - you can run later:${NC}"
            echo "   SSH_ALIAS=$SSH_ALIAS ./local/setup-supabase-migrations.sh"
        }
    else
        echo -e "${YELLOW}⚠️  Missing database preparation script${NC}"
    fi

    # 2. Consolidated Supabase configuration (Site URL, CAPTCHA, email templates)
    if [ -n "$SUPABASE_TOKEN" ] && [ -n "$PROJECT_REF" ]; then
        # Use function from lib/gateflow-setup.sh
        # Passes: domain, turnstile secret, SSH alias (for fetching email templates)
        configure_supabase_settings "$DOMAIN" "$GATEFLOW_TURNSTILE_SECRET" "$SSH_ALIAS" || {
            echo -e "${YELLOW}⚠️  Partial Supabase configuration${NC}"
        }
    fi
    # Reminders (Stripe, Turnstile, SMTP) will be displayed at the end
fi

# =============================================================================
# PHASE 3: DOMAIN CONFIGURATION (after service is running!)
# =============================================================================

# Check if install.sh saved a port (for dynamic ports like Docker static sites)
INSTALLED_PORT=$(server_exec "cat /tmp/app_port 2>/dev/null; rm -f /tmp/app_port" 2>/dev/null)
if [ -n "$INSTALLED_PORT" ]; then
    APP_PORT="$INSTALLED_PORT"
fi

# Check if install.sh saved STACK_DIR (for multi-instance apps like WordPress)
INSTALLED_STACK_DIR=$(server_exec "cat /tmp/app_stack_dir 2>/dev/null; rm -f /tmp/app_stack_dir" 2>/dev/null)
APP_STACK_DIR="${INSTALLED_STACK_DIR:-/opt/stacks/$APP_NAME}"

if [ "$NEEDS_DOMAIN" = true ] && [ "$DOMAIN_TYPE" != "local" ]; then
    echo ""
    if configure_domain "$APP_PORT" "$SSH_ALIAS"; then
        # Wait for domain to start responding (timeout 90s)
        wait_for_domain 90
    else
        echo ""
        echo -e "${YELLOW}Service is running, but domain configuration failed.${NC}"
        echo "   You can configure the domain manually later."
    fi
fi

# DOMAIN_PUBLIC configuration (for FileBrowser and similar)
if [ -n "$DOMAIN_PUBLIC" ]; then
    echo ""
    echo "Configuring public domain: $DOMAIN_PUBLIC"

    WEBROOT=$(server_exec "cat /tmp/domain_public_webroot 2>/dev/null || echo /var/www/public")

    # Configure DNS via Cloudflare if available
    if [ -f "$REPO_ROOT/local/dns-add.sh" ]; then
        "$REPO_ROOT/local/dns-add.sh" "$DOMAIN_PUBLIC" "$SSH_ALIAS" || echo "   DNS already configured or error - continuing"
    fi

    # Configure Caddy file_server
    if server_exec "command -v sp-expose &>/dev/null && sp-expose '$DOMAIN_PUBLIC' '$WEBROOT' static"; then
        echo -e "   ${GREEN}Static hosting configured: https://$DOMAIN_PUBLIC${NC}"
    else
        echo -e "   ${YELLOW}Failed to configure Caddy for $DOMAIN_PUBLIC${NC}"
    fi
    # Cleanup
    server_exec "rm -f /tmp/domain_public_webroot" 2>/dev/null
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  🎉 DONE!                                                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"

if [ "$DOMAIN_TYPE" = "local" ]; then
    echo ""
    echo "📋 Access via SSH tunnel:"
    echo -e "   ${BLUE}ssh -L $APP_PORT:localhost:$APP_PORT $SSH_ALIAS${NC}"
    echo "   Then open: http://localhost:$APP_PORT"
elif [ -n "$DOMAIN" ]; then
    echo ""
    echo -e "🌐 Application available at: ${BLUE}https://$DOMAIN${NC}"
fi

# Backup suggestion for database applications
if [ "$NEEDS_DB" = true ]; then
    echo ""
    echo -e "${YELLOW}💾 IMPORTANT: Your data is stored in a database!${NC}"
    echo "   If you don't have database backups configured, consider:"
    echo ""
    echo "   Configure automatic backup:"
    echo -e "      ${BLUE}ssh $SSH_ALIAS \"bash /opt/stackpilot/system/setup-db-backup.sh\"${NC}"
    echo ""
fi

# Post-installation reminders for GateFlow
if [ "$APP_NAME" = "gateflow" ]; then
    # Determine if Turnstile is configured
    TURNSTILE_CONFIGURED=false
    [ -n "$GATEFLOW_TURNSTILE_SECRET" ] && TURNSTILE_CONFIGURED=true

    echo ""
    echo -e "${YELLOW}📋 Next steps:${NC}"
    gateflow_show_post_install_reminders "$DOMAIN" "$SSH_ALIAS" "$GATEFLOW_STRIPE_CONFIGURED" "$TURNSTILE_CONFIGURED"
fi

# =============================================================================
# SERVER HEALTH (after installation)
# =============================================================================

POST_RESOURCES=$(server_exec_timeout 10 "free -m | awk '/^Mem:/ {print \$2, \$7}'; df -m / | awk 'NR==2 {print \$2, \$4}'" 2>/dev/null)
POST_RAM_LINE=$(echo "$POST_RESOURCES" | sed -n '1p')
POST_DISK_LINE=$(echo "$POST_RESOURCES" | sed -n '2p')

POST_RAM_TOTAL=$(echo "$POST_RAM_LINE" | awk '{print $1}')
POST_RAM_AVAIL=$(echo "$POST_RAM_LINE" | awk '{print $2}')
POST_DISK_TOTAL=$(echo "$POST_DISK_LINE" | awk '{print $1}')
POST_DISK_AVAIL=$(echo "$POST_DISK_LINE" | awk '{print $2}')

if [ -n "$POST_RAM_TOTAL" ] && [ "$POST_RAM_TOTAL" -gt 0 ] 2>/dev/null && \
   [ -n "$POST_DISK_TOTAL" ] && [ "$POST_DISK_TOTAL" -gt 0 ] 2>/dev/null; then

    RAM_USED_PCT=$(( (POST_RAM_TOTAL - POST_RAM_AVAIL) * 100 / POST_RAM_TOTAL ))
    DISK_USED_PCT=$(( (POST_DISK_TOTAL - POST_DISK_AVAIL) * 100 / POST_DISK_TOTAL ))
    DISK_AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $POST_DISK_AVAIL / 1024}")
    DISK_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $POST_DISK_TOTAL / 1024}")

    # RAM label
    if [ "$RAM_USED_PCT" -gt 80 ]; then
        RAM_LABEL="${RED}CRITICAL${NC}"
        RAM_LEVEL=2
    elif [ "$RAM_USED_PCT" -gt 60 ]; then
        RAM_LABEL="${YELLOW}TIGHT${NC}"
        RAM_LEVEL=1
    else
        RAM_LABEL="${GREEN}OK${NC}"
        RAM_LEVEL=0
    fi

    # Disk label
    if [ "$DISK_USED_PCT" -gt 85 ]; then
        DISK_LABEL="${RED}CRITICAL${NC}"
        DISK_LEVEL=2
    elif [ "$DISK_USED_PCT" -gt 60 ]; then
        DISK_LABEL="${YELLOW}TIGHT${NC}"
        DISK_LEVEL=1
    else
        DISK_LABEL="${GREEN}OK${NC}"
        DISK_LEVEL=0
    fi

    # Worst level
    HEALTH_LEVEL=$RAM_LEVEL
    [ "$DISK_LEVEL" -gt "$HEALTH_LEVEL" ] && HEALTH_LEVEL=$DISK_LEVEL

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  📊 Server health after installation                            ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo -e "   RAM:  ${POST_RAM_AVAIL}MB / ${POST_RAM_TOTAL}MB free (${RAM_USED_PCT}% used) — $RAM_LABEL"
    echo -e "   Disk: ${DISK_AVAIL_GB}GB / ${DISK_TOTAL_GB}GB free (${DISK_USED_PCT}% used) — $DISK_LABEL"
    echo ""

    if [ "$HEALTH_LEVEL" -eq 0 ]; then
        echo -e "   ${GREEN}✅ Server is in good shape. You can safely add more services.${NC}"
    elif [ "$HEALTH_LEVEL" -eq 1 ]; then
        echo -e "   ${YELLOW}⚠️  Getting tight. Consider upgrading before adding heavy services.${NC}"
    else
        echo -e "   ${RED}❌ Server is heavily loaded! Consider upgrading or removing unused services.${NC}"
    fi

    # Upgrade suggestion
    if [ "$HEALTH_LEVEL" -ge 1 ]; then
        UPGRADE=""
        if [ "$POST_RAM_TOTAL" -le 1024 ]; then
            UPGRADE="a VPS plan with 2GB RAM"
        elif [ "$POST_RAM_TOTAL" -le 2048 ]; then
            UPGRADE="a VPS plan with 4GB RAM"
        elif [ "$POST_RAM_TOTAL" -le 4096 ]; then
            UPGRADE="a VPS plan with 8GB RAM"
        elif [ "$POST_RAM_TOTAL" -le 8192 ]; then
            UPGRADE="a VPS plan with 16GB RAM"
        fi
        if [ -n "$UPGRADE" ]; then
            echo -e "   ${YELLOW}📦 Suggested upgrade: $UPGRADE${NC}"
        fi
    fi
fi

echo ""
