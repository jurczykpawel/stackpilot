#!/bin/bash

# StackPilot - CLI Parser
# Universal argument parser for all scripts.
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   source "$REPO_ROOT/lib/cli-parser.sh"
#   parse_args "$@"
#
# Value priority:
#   1. CLI flags (--db-host=...)          <- highest
#   2. Environment variables (DB_HOST=...)
#   3. Config file (~/.config/stackpilot/defaults.sh)
#   4. Interactive prompts                <- fallback
#
# Available after parse_args():
#   $SSH_ALIAS, $DB_SOURCE, $DB_HOST, $DB_PORT, $DB_NAME, $DB_SCHEMA,
#   $DB_USER, $DB_PASS, $DOMAIN, $DOMAIN_TYPE, $YES_MODE, $DRY_RUN,
#   ${POSITIONAL_ARGS[@]}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# ENVIRONMENT DETECTION (Git Bash / WSL / etc.)
# =============================================================================

detect_environment() {
    # Detect Git Bash / MINGW / MSYS
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "mingw"* ]] || [[ -n "$MSYSTEM" ]]; then
        IS_GITBASH=true

        # Check if this is MinTTY (problematic) or Windows Terminal (OK)
        # MinTTY does not set WT_SESSION, Windows Terminal does
        if [[ -z "$WT_SESSION" ]] && [[ "$TERM_PROGRAM" != "vscode" ]]; then
            IS_MINTTY=true
        else
            IS_MINTTY=false
        fi
    else
        IS_GITBASH=false
        IS_MINTTY=false
    fi

    export IS_GITBASH IS_MINTTY
}

# Show warning for Git Bash + MinTTY (only once, only in interactive mode)
warn_gitbash_mintty() {
    # Skip if already shown, in --yes mode, or not Git Bash
    if [[ "$GITBASH_WARNING_SHOWN" == "true" ]] || [[ "$YES_MODE" == "true" ]] || [[ "$IS_MINTTY" != "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠️  Git Bash with MinTTY detected                              ║${NC}"
    echo -e "${YELLOW}╠════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║  Interactive mode may not work correctly.                       ║${NC}"
    echo -e "${YELLOW}║                                                                ║${NC}"
    echo -e "${YELLOW}║  Solutions:                                                     ║${NC}"
    echo -e "${YELLOW}║  1. Use Windows Terminal instead of MinTTY                      ║${NC}"
    echo -e "${YELLOW}║  2. Run: winpty ./local/deploy.sh ...                           ║${NC}"
    echo -e "${YELLOW}║  3. Use automatic mode: --yes                                   ║${NC}"
    echo -e "${YELLOW}║  4. Install WSL2 (best solution)                                ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    export GITBASH_WARNING_SHOWN=true
}

# Run detection immediately
detect_environment

# Global variables (don't reset if already set by env)
export SSH_ALIAS="${SSH_ALIAS:-}"
export DB_SOURCE="${DB_SOURCE:-}"
export DB_HOST="${DB_HOST:-}"
export DB_PORT="${DB_PORT:-}"
export DB_NAME="${DB_NAME:-}"
export DB_SCHEMA="${DB_SCHEMA:-}"
export DB_USER="${DB_USER:-}"
export DB_PASS="${DB_PASS:-}"
export DOMAIN="${DOMAIN:-}"
export DOMAIN_TYPE="${DOMAIN_TYPE:-}"
export SUPABASE_PROJECT="${SUPABASE_PROJECT:-}"
export INSTANCE="${INSTANCE:-}"
export APP_PORT="${APP_PORT:-}"
export YES_MODE="${YES_MODE:-false}"
export DRY_RUN="${DRY_RUN:-false}"
export UPDATE_MODE="${UPDATE_MODE:-false}"
export RESTART_ONLY="${RESTART_ONLY:-false}"
export POSITIONAL_ARGS=()

# Config file path
CONFIG_FILE="$HOME/.config/stackpilot/defaults.sh"

# =============================================================================
# LOADING CONFIGURATION
# =============================================================================

load_defaults() {
    # Load config file if it exists
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    # Set default values from config or hardcoded defaults
    SSH_ALIAS="${SSH_ALIAS:-${DEFAULT_SSH:-vps}}"
    DB_PORT="${DB_PORT:-${DEFAULT_DB_PORT:-5432}}"
    DB_SCHEMA="${DB_SCHEMA:-${DEFAULT_DB_SCHEMA:-public}}"
    DOMAIN_TYPE="${DOMAIN_TYPE:-${DEFAULT_DOMAIN_TYPE:-}}"
}

# =============================================================================
# ARGUMENT PARSER
# =============================================================================

parse_args() {
    POSITIONAL_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            # SSH
            --ssh=*) SSH_ALIAS="${1#*=}" ;;
            --ssh) SSH_ALIAS="$2"; shift ;;

            # Database
            --db-source=*) DB_SOURCE="${1#*=}" ;;
            --db-source) DB_SOURCE="$2"; shift ;;
            --db-host=*) DB_HOST="${1#*=}" ;;
            --db-host) DB_HOST="$2"; shift ;;
            --db-port=*) DB_PORT="${1#*=}" ;;
            --db-port) DB_PORT="$2"; shift ;;
            --db-name=*) DB_NAME="${1#*=}" ;;
            --db-name) DB_NAME="$2"; shift ;;
            --db-schema=*) DB_SCHEMA="${1#*=}" ;;
            --db-schema) DB_SCHEMA="$2"; shift ;;
            --db-user=*) DB_USER="${1#*=}" ;;
            --db-user) DB_USER="$2"; shift ;;
            --db-pass=*) DB_PASS="${1#*=}" ;;
            --db-pass) DB_PASS="$2"; shift ;;

            # Domain
            --domain=*) DOMAIN="${1#*=}" ;;
            --domain) DOMAIN="$2"; shift ;;
            --domain-type=*) DOMAIN_TYPE="${1#*=}" ;;
            --domain-type) DOMAIN_TYPE="$2"; shift ;;

            # Supabase (for GateFlow)
            --supabase-project=*) SUPABASE_PROJECT="${1#*=}" ;;
            --supabase-project) SUPABASE_PROJECT="$2"; shift ;;

            # Multi-instance
            --instance=*) INSTANCE="${1#*=}" ;;
            --instance) INSTANCE="$2"; shift ;;
            --port=*) APP_PORT="${1#*=}" ;;
            --port) APP_PORT="$2"; shift ;;

            # Modes
            --yes|-y) YES_MODE=true ;;
            --dry-run) DRY_RUN=true ;;
            --update) UPDATE_MODE=true ;;
            --restart) RESTART_ONLY=true ;;
            --build-file=*) BUILD_FILE="${1#*=}" ;;
            --build-file) BUILD_FILE="$2"; shift ;;
            --help|-h) show_help; exit 0 ;;

            # Unknown options
            --*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                echo "Use --help to see available options." >&2
                exit 1
                ;;

            # Positional arguments
            *)
                POSITIONAL_ARGS+=("$1")
                ;;
        esac
        shift
    done

    # Export variables
    export SSH_ALIAS DB_SOURCE DB_HOST DB_PORT DB_NAME DB_SCHEMA DB_USER DB_PASS
    export DOMAIN DOMAIN_TYPE SUPABASE_PROJECT INSTANCE APP_PORT
    export YES_MODE DRY_RUN UPDATE_MODE RESTART_ONLY BUILD_FILE
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    local SCRIPT_NAME="${0##*/}"
    cat <<EOF
StackPilot - $SCRIPT_NAME

Usage:
  $SCRIPT_NAME APP [options]

SSH options:
  --ssh=ALIAS          SSH alias from ~/.ssh/config (default: vps)

Database options:
  --db-source=TYPE     Database source: shared (provider API) or custom
  --db-host=HOST       Database host
  --db-port=PORT       Database port (default: 5432)
  --db-name=NAME       Database name
  --db-schema=SCHEMA   PostgreSQL schema (default: public)
  --db-user=USER       Database user
  --db-pass=PASS       Database password

Domain options:
  --domain=DOMAIN      Application domain (e.g. app.example.com)
  --domain-type=TYPE   Type: cytrus, cloudflare, local

GateFlow options:
  --supabase-project=REF  Supabase project ref (skips interactive selection)
  --instance=NAME         Instance name (for multi-instance, e.g. --instance=shop)
  --port=PORT             Application port (default: auto-increment from 3333)

Modes:
  --yes, -y            Skip all confirmations (requires full parameters)
  --dry-run            Show what would be executed without running it
  --update             Update an existing application
  --restart            Restart without updating (e.g. after .env change) - used with --update
  --help, -h           Show this help

Examples:
  # Interactive (prompts for missing data)
  $SCRIPT_NAME n8n --ssh=vps

  # Full automation
  $SCRIPT_NAME n8n --ssh=vps --db-source=shared --domain=n8n.example.com --yes

  # Custom database
  $SCRIPT_NAME n8n --ssh=vps --db-source=custom --db-host=psql.example.com \\
    --db-name=n8n --db-user=myuser --db-pass=secret --domain=n8n.example.com --yes

Config file:
  ~/.config/stackpilot/defaults.sh
  Example:
    export DEFAULT_SSH="vps"
    export DEFAULT_DB_PORT="5432"
    export DEFAULT_DOMAIN_TYPE="cytrus"

EOF
}

# =============================================================================
# HELPER: ASK ONLY WHEN VALUE IS MISSING
# =============================================================================

# ask_if_empty VAR_NAME "Prompt" [default] [secret]
# Example: ask_if_empty DB_HOST "Database host"
# Example: ask_if_empty DB_PORT "Port" "5432"
# Example: ask_if_empty DB_PASS "Password" "" true
ask_if_empty() {
    local VAR_NAME="$1"
    local PROMPT="$2"
    local DEFAULT="${3:-}"
    local SECRET="${4:-false}"

    # Check if variable already has a value
    if [ -n "${!VAR_NAME}" ]; then
        return 0
    fi

    # --yes mode without value = error
    if [ "$YES_MODE" = true ]; then
        echo -e "${RED}Error: --${VAR_NAME,,} is required in --yes mode${NC}" >&2
        exit 1
    fi

    # Dry-run - don't ask
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[dry-run] Missing value for $VAR_NAME${NC}"
        return 0
    fi

    # Ask interactively
    local VALUE
    if [ "$SECRET" = true ]; then
        read -sp "$PROMPT: " VALUE
        echo
    elif [ -n "$DEFAULT" ]; then
        read -p "$PROMPT [$DEFAULT]: " VALUE
        VALUE="${VALUE:-$DEFAULT}"
    else
        read -p "$PROMPT: " VALUE
    fi

    # Set variable (printf -v instead of eval - safe for values with quotes)
    printf -v "$VAR_NAME" '%s' "$VALUE"
    export "$VAR_NAME"
}

# =============================================================================
# HELPER: CHOICE FROM OPTIONS
# =============================================================================

# ask_choice VAR_NAME "Prompt" "opt1|opt2|opt3" [default_index]
# Example: ask_choice DB_SOURCE "Choose database source" "shared|custom" 1
ask_choice() {
    local VAR_NAME="$1"
    local PROMPT="$2"
    local OPTIONS="$3"
    local DEFAULT_INDEX="${4:-}"

    # Check if variable already has a value
    if [ -n "${!VAR_NAME}" ]; then
        return 0
    fi

    # --yes mode without value = error
    if [ "$YES_MODE" = true ]; then
        echo -e "${RED}Error: --${VAR_NAME,,} is required in --yes mode${NC}" >&2
        exit 1
    fi

    # Dry-run - don't ask
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[dry-run] Missing value for $VAR_NAME${NC}"
        return 0
    fi

    # Parse options
    IFS='|' read -ra OPTS <<< "$OPTIONS"

    echo ""
    echo "$PROMPT"
    echo ""
    local i=1
    for opt in "${OPTS[@]}"; do
        local marker=""
        if [ "$i" = "$DEFAULT_INDEX" ]; then
            marker=" (default)"
        fi
        echo "  $i) $opt$marker"
        ((i++))
    done
    echo ""

    local CHOICE
    read -p "Choose [1-${#OPTS[@]}]: " CHOICE

    # Use default if empty
    if [ -z "$CHOICE" ] && [ -n "$DEFAULT_INDEX" ]; then
        CHOICE="$DEFAULT_INDEX"
    fi

    # Validation
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#OPTS[@]}" ]; then
        echo -e "${RED}Invalid choice${NC}" >&2
        return 1
    fi

    # Set variable (printf -v instead of eval - safe for values with special characters)
    local VALUE="${OPTS[$((CHOICE-1))]}"
    printf -v "$VAR_NAME" '%s' "$VALUE"
    export "$VAR_NAME"
}

# =============================================================================
# HELPER: CONFIRMATION
# =============================================================================

# confirm "Continue?"
# Returns 0 (true) or 1 (false)
confirm() {
    local MESSAGE="$1"

    # --yes mode = always yes
    if [ "$YES_MODE" = true ]; then
        return 0
    fi

    # Dry-run = always yes (but we don't do anything)
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[dry-run] Auto-confirmed: $MESSAGE${NC}"
        return 0
    fi

    read -p "$MESSAGE (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[TtYy]$ ]]
}

# =============================================================================
# HELPER: DRY-RUN OUTPUT
# =============================================================================

# dry_run_cmd "description" "command"
# In dry-run mode displays the command, in normal mode executes it
dry_run_cmd() {
    local DESC="$1"
    local CMD="$2"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[dry-run] $DESC:${NC}"
        echo "  $CMD"
        return 0
    fi

    # Direct invocation (without eval - avoids command injection)
    bash -c "$CMD"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f detect_environment
export -f warn_gitbash_mintty
export -f load_defaults
export -f parse_args
export -f show_help
export -f ask_if_empty
export -f ask_choice
export -f confirm
export -f dry_run_cmd
