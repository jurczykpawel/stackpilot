#!/bin/bash

# StackPilot - Domain Setup Helper
# Used by installation scripts to configure the domain.
# Author: Pawel (Lazy Engineer)
#
# NEW FLOW with CLI:
#   1. parse_args() + load_defaults()  - from cli-parser.sh
#   2. ask_domain()       - checks flags, only asks when missing
#   3. configure_domain() - configures domain (after starting the service!)
#
# CLI flags:
#   --domain-type=cloudflare|caddy|local
#   --domain=DOMAIN
#
# Available variables after calling:
#   $DOMAIN_TYPE  - "cloudflare" | "caddy" | "local"
#   $DOMAIN       - full domain, or "" for local

# Load cli-parser if not loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! type ask_if_empty &>/dev/null; then
    source "$SCRIPT_DIR/cli-parser.sh"
fi

# Load server-exec if not loaded
if ! type is_on_server &>/dev/null; then
    source "$SCRIPT_DIR/server-exec.sh"
fi

# Load i18n if not loaded
_DOM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_DOM_DIR/i18n.sh"
fi

CLOUDFLARE_CONFIG="$HOME/.config/cloudflare/config"

# Colors (if not defined by cli-parser)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
NC="${NC:-\033[0m}"

# Exported variables (don't reset if already set)
export DOMAIN="${DOMAIN:-}"
export DOMAIN_TYPE="${DOMAIN_TYPE:-}"

# =============================================================================
# PHASE 1: Gathering information (respects CLI flags)
# =============================================================================

ask_domain() {
    local APP_NAME="$1"
    local PORT="$2"
    local SSH_ALIAS="${3:-${SSH_ALIAS:-vps}}"

    # If DOMAIN_TYPE already set from CLI
    if [ -n "$DOMAIN_TYPE" ]; then
        # Value validation (core types + provider-specific types)
        case "$DOMAIN_TYPE" in
            cloudflare|caddy|local|cytrus) ;;
            *)
                msg "$MSG_DOM_INVALID_TYPE" >&2
                return 1
                ;;
        esac

        # Cytrus (Mikrus provider) — delegate to provider hook
        if [ "$DOMAIN_TYPE" = "cytrus" ]; then
            if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "auto" ]; then
                export DOMAIN="-"
            fi
            # Domain will be registered post-deploy via provider_post_deploy hook
            msg "$MSG_DOM_DOMAIN_SET" "$DOMAIN" "$DOMAIN_TYPE"
            return 0
        fi

        # local doesn't need a public domain, but keep DOMAIN if provided
        # (install.sh may use domain for instance naming, e.g. WordPress multi-instance)
        if [ "$DOMAIN_TYPE" = "local" ]; then
            if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "auto" ]; then
                export DOMAIN=""
            fi
            msg "$MSG_DOM_MODE_LOCAL"
            return 0
        fi

        # Cloudflare/Caddy requires DOMAIN
        if [ -z "$DOMAIN" ]; then
            if [ "$YES_MODE" = true ]; then
                msg "$MSG_DOM_DOMAIN_REQUIRED" "$DOMAIN_TYPE" >&2
                return 1
            fi
            # Interactive mode - ask for it
            if [ "$DOMAIN_TYPE" = "cloudflare" ]; then
                ask_domain_cloudflare "$APP_NAME"
            else
                ask_domain_caddy "$APP_NAME"
            fi
            return $?
        fi

        # Validate: for Cloudflare, check root domain is in config
        if [ "$DOMAIN_TYPE" = "cloudflare" ] && [ -f "$CLOUDFLARE_CONFIG" ]; then
            local CLI_ROOT=$(echo "$DOMAIN" | rev | cut -d. -f1-2 | rev)
            if ! grep -q "^${CLI_ROOT}=" "$CLOUDFLARE_CONFIG"; then
                local AVAILABLE=$(grep -v "^#" "$CLOUDFLARE_CONFIG" | grep -v "API_TOKEN" | grep "=" | cut -d= -f1 | tr '\n' ' ')
                msg "$MSG_DOM_CF_NO_ACCESS" "$CLI_ROOT" >&2
                msg "$MSG_DOM_CF_AVAILABLE" "$AVAILABLE" >&2
                msg "$MSG_DOM_CF_ADD_DOMAIN" >&2
                return 1
            fi
        fi

        msg "$MSG_DOM_DOMAIN_SET" "$DOMAIN" "$DOMAIN_TYPE"
        return 0
    fi

    # --yes mode without --domain-type = error
    if [ "$YES_MODE" = true ]; then
        msg "$MSG_DOM_YES_REQUIRES" >&2
        return 1
    fi

    # Interactive mode
    echo ""
    msg "$MSG_DOM_HOW_ACCESS"
    echo ""

    msg "$MSG_DOM_OPT_CF"
    msg "$MSG_DOM_OPT_CF_DESC"
    msg "$MSG_DOM_OPT_CF_REQ"
    echo ""

    msg "$MSG_DOM_OPT_CADDY"
    msg "$MSG_DOM_OPT_CADDY_DESC"
    msg "$MSG_DOM_OPT_CADDY_REQ"
    echo ""

    msg "$MSG_DOM_OPT_LOCAL"
    msg "$MSG_DOM_OPT_LOCAL_DESC" "$PORT" "$PORT" "$SSH_ALIAS"
    msg "$MSG_DOM_OPT_LOCAL_REQ"

    # Provider-specific domain options (e.g. Cytrus on Mikrus)
    PROVIDER_DOMAIN_ADDED=false
    PROVIDER_DOMAIN_NUM=""
    if type provider_domain_options &>/dev/null; then
        provider_domain_options 4
    fi
    echo ""

    read -p "$(msg "$MSG_DOM_CHOOSE")" DOMAIN_CHOICE

    case $DOMAIN_CHOICE in
        1)
            export DOMAIN_TYPE="cloudflare"
            ask_domain_cloudflare "$APP_NAME"
            return $?
            ;;
        2)
            export DOMAIN_TYPE="caddy"
            ask_domain_caddy "$APP_NAME"
            return $?
            ;;
        3)
            export DOMAIN_TYPE="local"
            export DOMAIN=""
            echo ""
            msg "$MSG_DOM_SELECTED_LOCAL"
            return 0
            ;;
        *)
            # Check if it matches a provider-added option
            if [ "$PROVIDER_DOMAIN_ADDED" = true ] && [ "$DOMAIN_CHOICE" = "$PROVIDER_DOMAIN_NUM" ]; then
                export DOMAIN_TYPE="cytrus"
                export DOMAIN="-"
                echo ""
                msg "$MSG_DOM_DOMAIN_SET" "auto" "cytrus"
                return 0
            fi
            msg "$MSG_DOM_INVALID_CHOICE"
            return 1
            ;;
    esac
}

ask_domain_caddy() {
    local APP_NAME="$1"

    # If DOMAIN already set (from CLI)
    if [ -n "$DOMAIN" ]; then
        return 0
    fi

    echo ""
    msg "$MSG_DOM_CADDY_ENTER" "$APP_NAME"
    msg "$MSG_DOM_CADDY_A_RECORD"
    echo ""

    read -p "$(msg "$MSG_DOM_CADDY_PROMPT" "$APP_NAME")" FULL_DOMAIN

    if [ -z "$FULL_DOMAIN" ]; then
        msg "$MSG_DOM_CADDY_EMPTY"
        return 1
    fi

    export DOMAIN="$FULL_DOMAIN"
    echo ""
    msg "$MSG_DOM_SELECTED" "$DOMAIN"

    return 0
}

ask_domain_cloudflare() {
    local APP_NAME="$1"

    # If DOMAIN already set (from CLI)
    if [ -n "$DOMAIN" ]; then
        return 0
    fi

    if [ ! -f "$CLOUDFLARE_CONFIG" ]; then
        echo ""
        msg "$MSG_DOM_CF_NOT_CONFIGURED"
        msg "$MSG_DOM_CF_RUN_FIRST"
        return 1
    fi

    echo ""
    msg "$MSG_DOM_CF_CONFIGURED"
    echo ""

    # Get list of domains (only real domains - without spaces, with dot)
    local DOMAINS=()
    while IFS= read -r line; do
        # Filter: must contain dot, no spaces, no @
        if [[ "$line" == *.* ]] && [[ "$line" != *" "* ]] && [[ "$line" != *"@"* ]]; then
            DOMAINS+=("$line")
        fi
    done < <(grep -v "^#" "$CLOUDFLARE_CONFIG" | grep -v "API_TOKEN" | grep "=" | cut -d= -f1)

    local DOMAIN_COUNT=${#DOMAINS[@]}

    if [ "$DOMAIN_COUNT" -eq 0 ]; then
        msg "$MSG_DOM_CF_NO_DOMAINS"
        return 1
    fi

    local FULL_DOMAIN=""

    # If <= 3 domains, show ready-made suggestions
    if [ "$DOMAIN_COUNT" -le 3 ]; then
        msg "$MSG_DOM_CF_CHOOSE" "$APP_NAME"
        echo ""

        local i=1
        for domain in "${DOMAINS[@]}"; do
            echo "  $i) $APP_NAME.$domain"
            ((i++))
        done
        echo ""
        msg "$MSG_DOM_CF_OR_CUSTOM" "$APP_NAME"
        echo ""

        read -p "$(msg "$MSG_DOM_CF_CHOICE" "$DOMAIN_COUNT")" CHOICE

        # Check if it's a number
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$DOMAIN_COUNT" ]; then
            local SELECTED_DOMAIN="${DOMAINS[$((CHOICE-1))]}"
            FULL_DOMAIN="$APP_NAME.$SELECTED_DOMAIN"
        elif [ -n "$CHOICE" ]; then
            # Treat as manually typed domain - validate root domain
            FULL_DOMAIN="$CHOICE"
            local INPUT_ROOT=$(echo "$FULL_DOMAIN" | rev | cut -d. -f1-2 | rev)
            local DOMAIN_FOUND=false
            for domain in "${DOMAINS[@]}"; do
                if [ "$domain" = "$INPUT_ROOT" ]; then
                    DOMAIN_FOUND=true
                    break
                fi
            done
            if [ "$DOMAIN_FOUND" = false ]; then
                echo ""
                msg "$MSG_DOM_CF_NO_ACCESS" "$INPUT_ROOT"
                msg "$MSG_DOM_CF_AVAILABLE" "${DOMAINS[*]}"
                echo ""
                msg "$MSG_DOM_CF_ADD_DOMAIN"
                return 1
            fi
        else
            msg "$MSG_DOM_CF_NO_DOMAIN"
            return 1
        fi
    else
        # More than 3 domains - old mode
        msg "$MSG_DOM_CF_AVAILABLE_LIST"
        local i=1
        for domain in "${DOMAINS[@]}"; do
            echo "  $i) $domain"
            ((i++))
        done
        echo ""

        read -p "$(msg "$MSG_DOM_CF_ENTER_FULL" "$APP_NAME")" FULL_DOMAIN
    fi

    if [ -z "$FULL_DOMAIN" ]; then
        msg "$MSG_DOM_CF_EMPTY"
        return 1
    fi

    # Validate: root domain must be in Cloudflare config
    local INPUT_ROOT=$(echo "$FULL_DOMAIN" | rev | cut -d. -f1-2 | rev)
    local DOMAIN_FOUND=false
    for domain in "${DOMAINS[@]}"; do
        if [ "$domain" = "$INPUT_ROOT" ]; then
            DOMAIN_FOUND=true
            break
        fi
    done
    if [ "$DOMAIN_FOUND" = false ]; then
        echo ""
        msg "$MSG_DOM_CF_NO_ACCESS" "$INPUT_ROOT"
        msg "$MSG_DOM_CF_AVAILABLE" "${DOMAINS[*]}"
        echo ""
        msg "$MSG_DOM_CF_ADD_DOMAIN"
        return 1
    fi

    export DOMAIN="$FULL_DOMAIN"
    echo ""
    msg "$MSG_DOM_SELECTED" "$DOMAIN"

    return 0
}

# =============================================================================
# HELPER: Domain configuration summary
# =============================================================================

show_domain_summary() {
    echo ""
    msg "$MSG_DOM_SUMMARY"
    msg "$MSG_DOM_SUMMARY_TYPE" "$DOMAIN_TYPE"
    if [ "$DOMAIN_TYPE" = "local" ]; then
        msg "$MSG_DOM_SUMMARY_SSH"
    else
        msg "$MSG_DOM_SUMMARY_DOMAIN" "$DOMAIN"
    fi
    echo ""
}

# =============================================================================
# PHASE 2: Domain configuration (after starting the service!)
# =============================================================================

configure_domain() {
    local PORT="$1"
    local SSH_ALIAS="${2:-${SSH_ALIAS:-vps}}"

    # Dry-run mode
    if [ "$DRY_RUN" = true ]; then
        msg "$MSG_DOM_DRYRUN" "$DOMAIN_TYPE" "$DOMAIN"
        return 0
    fi

    # Local - nothing to do
    if [ "$DOMAIN_TYPE" = "local" ]; then
        echo ""
        msg "$MSG_DOM_LOCAL_ACCESS"
        msg "$MSG_DOM_LOCAL_CMD" "$PORT" "$PORT" "$SSH_ALIAS"
        msg "$MSG_DOM_LOCAL_OPEN" "$PORT"
        return 0
    fi

    # Caddy - configure reverse proxy on server
    if [ "$DOMAIN_TYPE" = "caddy" ]; then
        configure_domain_caddy "$PORT" "$SSH_ALIAS"
        return $?
    fi

    # Cloudflare - configure DNS + Caddy
    if [ "$DOMAIN_TYPE" = "cloudflare" ]; then
        configure_domain_cloudflare "$PORT" "$SSH_ALIAS"
        return $?
    fi

    msg "$MSG_DOM_UNKNOWN_TYPE" "$DOMAIN_TYPE"
    return 1
}

configure_domain_caddy() {
    local PORT="$1"
    local SSH_ALIAS="$2"

    echo ""
    msg "$MSG_DOM_CADDY_CONFIGURING"

    # Domain validation (preventing Caddyfile/shell injection)
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
        msg "$MSG_DOM_CADDY_INVALID" "$DOMAIN" >&2
        return 1
    fi

    # Check if this is a static site (look for /tmp/APP_webroot file, not domain_public_webroot)
    local WEBROOT=$(server_exec "ls /tmp/*_webroot 2>/dev/null | grep -v domain_public_webroot | head -1 | xargs cat 2>/dev/null" 2>/dev/null)

    if [ -n "$WEBROOT" ]; then
        # Static site (littlelink, etc.) - use file_server mode
        msg "$MSG_DOM_CADDY_STATIC" "$WEBROOT"
        if server_exec "command -v sp-expose &>/dev/null && sp-expose '$DOMAIN' '$WEBROOT' static"; then
            msg "$MSG_DOM_CADDY_FS_OK"
            # Remove marker (don't remove domain_public_webroot!)
            server_exec "ls /tmp/*_webroot 2>/dev/null | grep -v domain_public_webroot | xargs rm -f" 2>/dev/null
        else
            msg "$MSG_DOM_CADDY_EXPOSE_NA"
        fi
    else
        # Docker app - use reverse_proxy
        if server_exec "command -v sp-expose &>/dev/null && sp-expose '$DOMAIN' '$PORT'" 2>/dev/null; then
            msg "$MSG_DOM_CADDY_RP_OK"
        else
            # Check if domain is already in Caddyfile
            if server_exec "grep -q '$DOMAIN' /etc/caddy/Caddyfile 2>/dev/null"; then
                msg "$MSG_DOM_CADDY_ALREADY"
            else
                msg "$MSG_DOM_CADDY_EXPOSE_NA"
            fi
        fi
    fi

    echo ""
    msg "$MSG_DOM_CADDY_DONE" "$DOMAIN"
    echo ""
    msg "$MSG_DOM_CADDY_DNS_HINT"

    return 0
}

configure_domain_cloudflare() {
    local PORT="$1"
    local SSH_ALIAS="$2"

    local REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    local DNS_SCRIPT="$REPO_ROOT/local/dns-add.sh"
    local OPTIMIZE_SCRIPT="$REPO_ROOT/local/setup-cloudflare-optimize.sh"

    echo ""
    msg "$MSG_DOM_CF_CONFIGURING"

    # Domain validation (preventing Caddyfile/shell injection)
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
        msg "$MSG_DOM_CF_INVALID" "$DOMAIN" >&2
        return 1
    fi

    local DNS_OK=false
    if [ -f "$DNS_SCRIPT" ]; then
        if bash "$DNS_SCRIPT" "$DOMAIN" "$SSH_ALIAS"; then
            msg "$MSG_DOM_CF_DNS_OK" "$DOMAIN"
            DNS_OK=true
        else
            # Check if record already exists (dns-add.sh exits 0 when IP is the same)
            # So exit != 0 means a real error
            msg "$MSG_DOM_CF_DNS_FAILED"
            msg "$MSG_DOM_CF_DNS_CHECK" "$DOMAIN" "$SSH_ALIAS"
        fi
    else
        msg "$MSG_DOM_CF_DNS_MISSING"
    fi

    # Cloudflare settings optimization (SSL Full, cache, compression)
    if [ -f "$OPTIMIZE_SCRIPT" ]; then
        echo ""
        # Map APP_NAME to --app preset (if known)
        local CF_APP_FLAG=""
        case "${APP_NAME:-}" in
            wordpress) CF_APP_FLAG="--app=wordpress" ;;
            sellf)  CF_APP_FLAG="--app=nextjs" ;;
        esac
        bash "$OPTIMIZE_SCRIPT" "$DOMAIN" $CF_APP_FLAG || msg "$MSG_DOM_CF_OPT_SKIPPED"
    fi

    # Configure Caddy on server (even if DNS didn't need changes)
    echo ""
    msg "$MSG_DOM_CF_HTTPS"

    local CADDY_OK=false

    # Make sure Caddy + sp-expose is on the server
    if ! server_exec "command -v sp-expose &>/dev/null" 2>/dev/null; then
        msg "$MSG_DOM_CF_EXPOSE_MISSING"
        ensure_toolbox "$SSH_ALIAS"
        local CADDY_SCRIPT="$REPO_ROOT/system/caddy-install.sh"
        if [ -f "$CADDY_SCRIPT" ]; then
            server_exec "bash -s" < "$CADDY_SCRIPT" 2>&1 | tail -3
        else
            server_exec "bash -s" < <(curl -sL "https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/system/caddy-install.sh") 2>&1 | tail -3
        fi
    fi

    # Check if this is a static site (look for /tmp/APP_webroot file, not domain_public_webroot)
    # domain_public_webroot is for DOMAIN_PUBLIC, handled separately in deploy.sh
    local WEBROOT=$(server_exec "ls /tmp/*_webroot 2>/dev/null | grep -v domain_public_webroot | head -1 | xargs cat 2>/dev/null" 2>/dev/null)

    if [ -n "$WEBROOT" ]; then
        # Static site (littlelink, etc.) - use file_server mode
        msg "$MSG_DOM_CF_STATIC" "$WEBROOT"
        if server_exec "command -v sp-expose &>/dev/null && sp-expose '$DOMAIN' '$WEBROOT' static" 2>/dev/null; then
            msg "$MSG_DOM_CF_FS_OK"
            CADDY_OK=true
            # Remove marker (don't remove domain_public_webroot!)
            server_exec "ls /tmp/*_webroot 2>/dev/null | grep -v domain_public_webroot | xargs rm -f" 2>/dev/null
        fi
    else
        # Docker app - use reverse_proxy
        if server_exec "command -v sp-expose &>/dev/null && sp-expose '$DOMAIN' '$PORT' proxy" 2>/dev/null; then
            msg "$MSG_DOM_CF_RP_OK"
            CADDY_OK=true
        fi
    fi

    # Fallback: sp-expose may have refused because domain is already in Caddyfile — that's OK
    if [ "$CADDY_OK" = false ]; then
        if server_exec "grep -q '$DOMAIN' /etc/caddy/Caddyfile 2>/dev/null"; then
            msg "$MSG_DOM_CF_ALREADY"
            CADDY_OK=true
        fi
    fi

    if [ "$CADDY_OK" = false ]; then
        if server_exec "command -v sp-expose &>/dev/null" 2>/dev/null; then
            msg "$MSG_DOM_CF_EXPOSE_FAIL"
            msg "$MSG_DOM_CF_EXPOSE_CHECK" "$SSH_ALIAS"
        else
            msg "$MSG_DOM_CF_NOT_INSTALLED"
            msg "$MSG_DOM_CF_INSTALL_HINT" "$SSH_ALIAS"
        fi
    fi

    # Make sure Caddy is running
    if [ "$CADDY_OK" = true ]; then
        if ! server_exec "systemctl is-active --quiet caddy" 2>/dev/null; then
            msg "$MSG_DOM_CF_STARTING_CADDY"
            server_exec "systemctl start caddy && systemctl enable caddy 2>/dev/null" 2>/dev/null
        fi
    fi

    # Summary
    echo ""
    if [ "$DNS_OK" = true ] && [ "$CADDY_OK" = true ]; then
        msg "$MSG_DOM_CF_FULL_OK" "$DOMAIN"
    elif [ "$CADDY_OK" = true ]; then
        msg "$MSG_DOM_CF_CADDY_OK" "$DOMAIN"
    elif [ "$DNS_OK" = true ]; then
        msg "$MSG_DOM_CF_DNS_ONLY"
    else
        msg "$MSG_DOM_CF_BOTH_FAIL"
        return 1
    fi

    return 0
}

# =============================================================================
# PHASE 3: Verifying if domain works
# =============================================================================

wait_for_domain() {
    local TIMEOUT="${1:-60}"  # default 60 seconds

    if [ -z "$DOMAIN" ] || [ "$DOMAIN_TYPE" = "local" ]; then
        return 0
    fi

    # Dry-run mode
    if [ "$DRY_RUN" = true ]; then
        msg "$MSG_DOM_WAIT_DRYRUN" "$DOMAIN"
        return 0
    fi

    echo ""
    msg "$MSG_DOM_WAIT_CHECKING" "$DOMAIN"

    local START_TIME=$(date +%s)
    local SPINNER="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local SPINNER_IDX=0

    while true; do
        local CURRENT_TIME=$(date +%s)
        local ELAPSED=$((CURRENT_TIME - START_TIME))

        if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
            echo ""
            msg "$MSG_DOM_WAIT_TIMEOUT"
            echo ""

            # DNS diagnostics
            msg "$MSG_DOM_WAIT_DIAG"
            local DIG_RESULT=""
            if command -v dig &>/dev/null; then
                # Check A and AAAA (Cloudflare mode uses AAAA)
                DIG_RESULT=$(dig +short A "$DOMAIN" 2>/dev/null)
                if [ -z "$DIG_RESULT" ]; then
                    DIG_RESULT=$(dig +short AAAA "$DOMAIN" 2>/dev/null)
                fi
            elif command -v nslookup &>/dev/null; then
                DIG_RESULT=$(nslookup "$DOMAIN" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}')
            fi

            # For Cloudflare — also check if record exists in API
            local CF_RECORD_OK=false
            if [ "$DOMAIN_TYPE" = "cloudflare" ] && [ -f "$CLOUDFLARE_CONFIG" ]; then
                local DIAG_TOKEN=$(grep "^API_TOKEN=" "$CLOUDFLARE_CONFIG" | cut -d= -f2)
                local DIAG_ROOT=$(echo "$DOMAIN" | rev | cut -d. -f1-2 | rev)
                local DIAG_ZONE=$(grep "^${DIAG_ROOT}=" "$CLOUDFLARE_CONFIG" | cut -d= -f2)
                if [ -n "$DIAG_TOKEN" ] && [ -n "$DIAG_ZONE" ]; then
                    local CF_CHECK=$(curl -s "https://api.cloudflare.com/client/v4/zones/$DIAG_ZONE/dns_records?name=$DOMAIN" \
                        -H "Authorization: Bearer $DIAG_TOKEN" 2>/dev/null)
                    if echo "$CF_CHECK" | grep -q "\"name\":\"$DOMAIN\""; then
                        CF_RECORD_OK=true
                        local CF_TYPE=$(echo "$CF_CHECK" | grep -o '"type":"[^"]*"' | head -1 | sed 's/"type":"//;s/"//')
                        local CF_CONTENT=$(echo "$CF_CHECK" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"//')
                        local CF_PROXIED=$(echo "$CF_CHECK" | grep -o '"proxied":[a-z]*' | head -1 | sed 's/"proxied"://')
                        msg "$MSG_DOM_WAIT_CF_DNS" "$CF_TYPE" "$CF_CONTENT" "$CF_PROXIED"
                    fi
                fi
            fi

            if [ -n "$DIG_RESULT" ]; then
                msg "$MSG_DOM_WAIT_DNS_OK" "$DOMAIN" "$DIG_RESULT"
                if [ "$DOMAIN_TYPE" = "cloudflare" ]; then
                    msg "$MSG_DOM_WAIT_CF_EDGE"
                fi
            elif [ "$CF_RECORD_OK" = true ]; then
                msg "$MSG_DOM_WAIT_DNS_PROP"
                msg "$MSG_DOM_WAIT_DNS_PROP_HINT" "$DOMAIN"
            else
                msg "$MSG_DOM_WAIT_DNS_NONE"
                msg "$MSG_DOM_WAIT_DNS_CHECK" "$DOMAIN" "${SSH_ALIAS:-vps}"
            fi

            # Check HTTP (only when DNS resolves)
            if [ -n "$DIG_RESULT" ]; then
                local DIAG_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN" 2>/dev/null || echo "000")
                if [ "$DIAG_HTTP" = "000" ]; then
                    msg "$MSG_DOM_WAIT_HTTPS_NONE"
                elif [ "$DIAG_HTTP" = "521" ] || [ "$DIAG_HTTP" = "522" ] || [ "$DIAG_HTTP" = "523" ]; then
                    msg "$MSG_DOM_WAIT_HTTPS_CF" "$DIAG_HTTP"
                elif [ "$DIAG_HTTP" -ge 500 ]; then
                    msg "$MSG_DOM_WAIT_HTTPS_ERR" "$DIAG_HTTP"
                else
                    msg "$MSG_DOM_WAIT_HTTPS_OTHER" "$DIAG_HTTP"
                fi
            fi

            echo ""
            msg "$MSG_DOM_WAIT_CHECK_LATER" "$DOMAIN"
            # Timeout is just diagnostic info — deployment succeeded, DNS is propagating
            return 0
        fi

        # Check HTTP code
        local HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN" 2>/dev/null || echo "000")

        # Check HTTP 2xx-4xx (not 5xx)
        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 500 ]; then
            echo ""
            msg "$MSG_DOM_WAIT_WORKING" "$HTTP_CODE"
            return 0
        fi

        # Spinner
        local CHAR="${SPINNER:$SPINNER_IDX:1}"
        SPINNER_IDX=$(( (SPINNER_IDX + 1) % ${#SPINNER} ))
        printf "\r$(msg "$MSG_DOM_WAIT_CHECKING_SPIN" "$CHAR" "$ELAPSED" "$TIMEOUT")"

        sleep 3
    done
}

# =============================================================================
# OLD FLOW (backward compatibility)
# =============================================================================

# Old get_domain function - now calls new functions
get_domain() {
    local APP_NAME="$1"
    local PORT="$2"
    local SSH_ALIAS="${3:-${SSH_ALIAS:-vps}}"

    # Phase 1: gather choice
    if ! ask_domain "$APP_NAME" "$PORT" "$SSH_ALIAS"; then
        return 1
    fi

    # Phase 2: configure (old flow does it immediately)
    # NOTE: In the new flow configure_domain() is called AFTER starting the service!
    if [ "$DOMAIN_TYPE" != "local" ]; then
        if ! configure_domain "$PORT" "$SSH_ALIAS"; then
            return 1
        fi
    fi

    return 0
}

# Old setup_domain function
setup_domain() {
    local APP_NAME="$1"
    local PORT="$2"
    local SSH_ALIAS="${3:-${SSH_ALIAS:-vps}}"

    echo ""
    msg "$MSG_DOM_SETUP_TITLE" "$APP_NAME"

    get_domain "$APP_NAME" "$PORT" "$SSH_ALIAS"
    return $?
}

# Helper functions (for compatibility)
get_domain_cloudflare() {
    local APP_NAME="$1"
    local PORT="$2"
    local SSH_ALIAS="$3"

    export DOMAIN_TYPE="cloudflare"
    if ask_domain_cloudflare "$APP_NAME"; then
        configure_domain_cloudflare "$PORT" "$SSH_ALIAS"
        return $?
    fi
    return 1
}

setup_local_only() {
    local APP_NAME="$1"
    local PORT="$2"
    local SSH_ALIAS="$3"

    export DOMAIN_TYPE="local"
    export DOMAIN=""
    configure_domain "$PORT" "$SSH_ALIAS"
}

setup_cloudflare() {
    get_domain_cloudflare "$@"
}

# Export functions
export -f ask_domain
export -f ask_domain_caddy
export -f ask_domain_cloudflare
export -f show_domain_summary
export -f configure_domain
export -f configure_domain_caddy
export -f configure_domain_cloudflare
export -f wait_for_domain
export -f get_domain
export -f get_domain_cloudflare
export -f setup_domain
export -f setup_local_only
export -f setup_cloudflare
