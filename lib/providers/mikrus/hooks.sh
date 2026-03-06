#!/bin/bash

# StackPilot - Mikrus Provider Hooks
# Entry point for all Mikrus-specific functionality.
# Loaded automatically by lib/providers/detect.sh when provider=mikrus.

_MIKRUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load Mikrus modules
source "$_MIKRUS_DIR/cytrus.sh"
source "$_MIKRUS_DIR/shared-db.sh"

# =============================================================================
# HOOK: provider_domain_options
# Called by lib/domain-setup.sh during interactive domain type selection.
# Adds Cytrus as an additional domain option.
#
# Arguments:
#   $1 - current option number (next available number for the menu)
# Returns:
#   Prints the menu option. Sets PROVIDER_DOMAIN_ADDED=true if option added.
#   Returns the number of options added (0 or 1).
# =============================================================================

provider_domain_options() {
    local NEXT_NUM="${1:-4}"
    echo ""
    echo "  $NEXT_NUM) $(msg "$MSG_MPROV_DOM_OPT")"
    echo "     $(msg "$MSG_MPROV_DOM_OPT_DESC")"
    echo "     $(msg "$MSG_MPROV_DOM_OPT_REQ")"
    PROVIDER_DOMAIN_ADDED=true
    PROVIDER_DOMAIN_NUM="$NEXT_NUM"
    return 0
}

# =============================================================================
# HOOK: provider_db_options
# Called by lib/db-setup.sh during interactive DB source selection.
# Adds "shared" (Mikrus free database) as an additional option.
#
# Arguments:
#   $1 - current option number
#   $2 - DB_TYPE (postgres/mysql/mongo)
#   $3 - APP_NAME
# Returns:
#   Prints the menu option. Sets PROVIDER_DB_ADDED=true if option added.
# =============================================================================

provider_db_options() {
    local NEXT_NUM="${1:-3}"
    local DB_TYPE="${2:-postgres}"
    local APP_NAME="${3:-}"

    # Check if this app requires pgcrypto (incompatible with shared)
    local REQUIRES_PGCRYPTO="umami n8n listmonk"
    if echo "$REQUIRES_PGCRYPTO" | grep -qw "$APP_NAME"; then
        msg "$MSG_MDB_PGCRYPTO_WARN" "$APP_NAME"
        return 0
    fi

    echo ""
    echo "  $NEXT_NUM) $(msg "$MSG_MDB_OPT_SHARED")"
    echo "     $(msg "$MSG_MDB_OPT_SHARED_DESC")"
    echo ""
    PROVIDER_DB_ADDED=true
    PROVIDER_DB_NUM="$NEXT_NUM"
    return 0
}

# =============================================================================
# HOOK: provider_post_deploy
# Called by local/deploy.sh after successful app deployment.
# On Mikrus, registers a Cytrus domain if domain_type=cytrus.
#
# Arguments:
#   $1 - APP_NAME
#   $2 - PORT
#   $3 - DOMAIN (may be empty or "auto")
#   $4 - DOMAIN_TYPE
# =============================================================================

provider_post_deploy() {
    local APP_NAME="$1"
    local PORT="$2"
    local DOMAIN="${3:-}"
    local DOMAIN_TYPE="${4:-}"

    if [ "$DOMAIN_TYPE" = "cytrus" ]; then
        local CYTRUS_DOMAIN="${DOMAIN:-"-"}"
        cytrus_register_domain "$CYTRUS_DOMAIN" "$PORT" "${SSH_ALIAS:-vps}"
    fi
}

# =============================================================================
# HOOK: provider_upgrade_suggestion
# Called by lib/resource-check.sh when resources are low.
# Provides Mikrus-specific upgrade recommendations.
#
# Arguments:
#   $1 - STATUS (1=warn, 2=fail)
#   $2 - REQUIRED_RAM
# =============================================================================

provider_upgrade_suggestion() {
    local STATUS="$1"
    local REQUIRED_RAM="${2:-256}"

    if [ "$STATUS" -eq 2 ]; then
        msg "$MSG_MPROV_FAIL_HINT"
    elif [ "$REQUIRED_RAM" -ge 400 ]; then
        msg "$MSG_MPROV_HEAVY_APP"
        msg "$MSG_MPROV_HEAVY_REC"
    fi
}

export -f provider_domain_options provider_db_options provider_post_deploy provider_upgrade_suggestion
