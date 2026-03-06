#!/bin/bash

# StackPilot - Provider Detection
# Auto-detects the VPS provider and loads provider-specific hooks.
#
# Detection logic:
#   1. Config override: TOOLBOX_PROVIDER in ~/.config/stackpilot/config
#   2. Mikrus marker: /klucz_api exists on server
#   3. Fallback: generic (no provider-specific features)
#
# Usage:
#   source "$SCRIPT_DIR/../lib/providers/detect.sh"
#   # After sourcing, TOOLBOX_PROVIDER is set and hooks are loaded
#
# Hook functions available after loading:
#   provider_domain_options  - extra domain type choices for interactive menu
#   provider_db_options      - extra DB source choices for interactive menu
#   provider_post_deploy     - called after successful app deployment
#   provider_upgrade_suggestion - custom upgrade message for resource warnings

_PROV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# i18n (use guard — may already be loaded by parent script)
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_PROV_DIR/../i18n.sh"
fi

# =============================================================================
# DETECTION
# =============================================================================

detect_provider() {
    # 1. Config override
    local CONFIG_FILE="${HOME}/.config/stackpilot/config"
    if [ -f "$CONFIG_FILE" ]; then
        local OVERRIDE=$(grep "^TOOLBOX_PROVIDER=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
        if [ -n "$OVERRIDE" ]; then
            export TOOLBOX_PROVIDER="$OVERRIDE"
            msg "$MSG_PROV_OVERRIDE" "$OVERRIDE"
            return 0
        fi
    fi

    # 2. Mikrus marker: /klucz_api
    if [ -f /klucz_api ]; then
        export TOOLBOX_PROVIDER="mikrus"
        msg "$MSG_PROV_DETECTED" "mikrus"
        return 0
    fi

    # 3. Remote detection (if SSH_ALIAS is set and we're not on the server)
    if [ "${_ON_SERVER:-false}" != "true" ] && [ -n "${SSH_ALIAS:-}" ]; then
        if ssh -o ConnectTimeout=3 "${SSH_ALIAS}" 'test -f /klucz_api' 2>/dev/null; then
            export TOOLBOX_PROVIDER="mikrus"
            msg "$MSG_PROV_DETECTED" "mikrus"
            return 0
        fi
    fi

    # 4. Fallback: generic
    export TOOLBOX_PROVIDER="generic"
    return 0
}

# =============================================================================
# HOOK LOADING
# =============================================================================

load_provider_hooks() {
    local PROVIDER="${TOOLBOX_PROVIDER:-generic}"

    if [ "$PROVIDER" = "generic" ]; then
        # Define no-op hook functions for generic provider
        provider_domain_options() { return 0; }
        provider_db_options() { return 0; }
        provider_post_deploy() { return 0; }
        provider_upgrade_suggestion() { return 0; }
        export -f provider_domain_options provider_db_options provider_post_deploy provider_upgrade_suggestion
        return 0
    fi

    local HOOKS_FILE="$_PROV_DIR/$PROVIDER/hooks.sh"

    if [ -f "$HOOKS_FILE" ]; then
        msg "$MSG_PROV_LOADING" "$PROVIDER"
        source "$HOOKS_FILE"
    else
        msg "$MSG_PROV_NOT_FOUND" "$PROVIDER" "$HOOKS_FILE"
        # Still define no-op hooks so callers don't fail
        provider_domain_options() { return 0; }
        provider_db_options() { return 0; }
        provider_post_deploy() { return 0; }
        provider_upgrade_suggestion() { return 0; }
        export -f provider_domain_options provider_db_options provider_post_deploy provider_upgrade_suggestion
    fi
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Auto-detect when sourced on the server (i18n guard: check if already set)
# When sourced from local deploy.sh, detection is deferred until SSH_ALIAS is known
# Call detect_provider + load_provider_hooks manually after parse_args
if [ -z "${TOOLBOX_PROVIDER+x}" ]; then
    if [ -f /klucz_api ] || [ "${_ON_SERVER:-false}" = "true" ]; then
        # On the server — detect immediately
        detect_provider
        load_provider_hooks
    else
        # Local (laptop) — define no-op hooks as defaults, detect later
        provider_domain_options() { return 0; }
        provider_db_options() { return 0; }
        provider_post_deploy() { return 0; }
        provider_upgrade_suggestion() { return 0; }
        export -f provider_domain_options provider_db_options provider_post_deploy provider_upgrade_suggestion
    fi
fi

export TOOLBOX_PROVIDER
export -f detect_provider load_provider_hooks
