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

# i18n
_CP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_CP_DIR/i18n.sh"
fi

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
    printf "${YELLOW}║  %s${NC}\n" "$(msg "$MSG_CP_MINTTY_HEADER")                              ║"
    echo -e "${YELLOW}╠════════════════════════════════════════════════════════════════╣${NC}"
    printf "${YELLOW}║  %s${NC}\n" "$(msg "$MSG_CP_MINTTY_BODY")                       ║"
    echo -e "${YELLOW}║                                                                ║${NC}"
    echo -e "${YELLOW}║  Solutions:                                                     ║${NC}"
    printf "${YELLOW}║  %s${NC}\n" "$(msg "$MSG_CP_MINTTY_SOL1")                      ║"
    printf "${YELLOW}║  %s${NC}\n" "$(msg "$MSG_CP_MINTTY_SOL2")                           ║"
    printf "${YELLOW}║  %s${NC}\n" "$(msg "$MSG_CP_MINTTY_SOL3")                                   ║"
    printf "${YELLOW}║  %s${NC}\n" "$(msg "$MSG_CP_MINTTY_SOL4")                        ║"
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

            # Supabase (for Sellf)
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
                msg "$MSG_CP_UNKNOWN_OPTION" "$1" >&2
                msg "$MSG_CP_UNKNOWN_HINT" >&2
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
    printf "$(msg "$MSG_CP_HELP_TITLE")\n\n" "$SCRIPT_NAME"
    printf "%s\n" "$(msg "$MSG_CP_HELP_USAGE")"
    printf "  %s %s\n\n" "$SCRIPT_NAME" "APP [options]"
    printf "%s\n" "$(msg "$MSG_CP_HELP_SSH")"
    printf "%s\n\n" "$(msg "$MSG_CP_HELP_SSH_ALIAS")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_DB")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_DB_SOURCE")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_DB_HOST")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_DB_PORT")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_DB_NAME")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_DB_SCHEMA")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_DB_USER")"
    printf "%s\n\n" "$(msg "$MSG_CP_HELP_DB_PASS")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_DOMAIN")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_DOMAIN_FLAG")"
    printf "%s\n\n" "$(msg "$MSG_CP_HELP_DOMAIN_TYPE")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_SELLF")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_SUPABASE")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_INSTANCE")"
    printf "%s\n\n" "$(msg "$MSG_CP_HELP_PORT")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_MODES")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_YES")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_DRYRUN")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_UPDATE")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_RESTART")"
    printf "%s\n\n" "$(msg "$MSG_CP_HELP_HELP")"
    printf "%s\n" "$(msg "$MSG_CP_HELP_EXAMPLES")"
    printf "  # Interactive (prompts for missing data)\n"
    printf "  %s n8n --ssh=vps\n\n" "$SCRIPT_NAME"
    printf "  # Full automation\n"
    printf "  %s n8n --ssh=vps --db-source=bundled --domain=n8n.example.com --yes\n\n" "$SCRIPT_NAME"
    printf "  # Custom database\n"
    printf "  %s n8n --ssh=vps --db-source=custom --db-host=psql.example.com \\\\\n" "$SCRIPT_NAME"
    printf "    --db-name=n8n --db-user=myuser --db-pass=secret --domain=n8n.example.com --yes\n\n"
    printf "%s\n" "$(msg "$MSG_CP_HELP_CONFIG")"
    printf "  ~/.config/stackpilot/defaults.sh\n"
    printf "  Example:\n"
    printf "    export DEFAULT_SSH=\"vps\"\n"
    printf "    export DEFAULT_DB_PORT=\"5432\"\n"
    printf "    export DEFAULT_DOMAIN_TYPE=\"cloudflare\"\n\n"
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
        msg "$MSG_CP_REQUIRED_YES" "${VAR_NAME,,}" >&2
        exit 1
    fi

    # Dry-run - don't ask
    if [ "$DRY_RUN" = true ]; then
        msg "$MSG_CP_MISSING_DRYRUN" "$VAR_NAME"
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
# Example: ask_choice DB_SOURCE "Choose database source" "bundled|custom" 1
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
        msg "$MSG_CP_REQUIRED_YES" "${VAR_NAME,,}" >&2
        exit 1
    fi

    # Dry-run - don't ask
    if [ "$DRY_RUN" = true ]; then
        msg "$MSG_CP_MISSING_DRYRUN" "$VAR_NAME"
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
            marker="$(msg "$MSG_CP_DEFAULT")"
        fi
        echo "  $i) $opt$marker"
        ((i++))
    done
    echo ""

    local CHOICE
    read -p "$(msg "$MSG_CP_CHOOSE" "${#OPTS[@]}")" CHOICE

    # Use default if empty
    if [ -z "$CHOICE" ] && [ -n "$DEFAULT_INDEX" ]; then
        CHOICE="$DEFAULT_INDEX"
    fi

    # Validation
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#OPTS[@]}" ]; then
        msg "$MSG_CP_INVALID_CHOICE" >&2
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
        msg "$MSG_CP_DRYRUN_CONFIRM" "$MESSAGE"
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
        msg "$MSG_CP_DRYRUN_CMD" "$DESC"
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
