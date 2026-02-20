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
        # Value validation
        case "$DOMAIN_TYPE" in
            cloudflare|caddy|local) ;;
            *)
                echo -e "${RED}Error: --domain-type must be: cloudflare, caddy or local${NC}" >&2
                return 1
                ;;
        esac

        # local doesn't need a public domain, but keep DOMAIN if provided
        # (install.sh may use domain for instance naming, e.g. WordPress multi-instance)
        if [ "$DOMAIN_TYPE" = "local" ]; then
            if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "auto" ]; then
                export DOMAIN=""
            fi
            echo -e "${GREEN}Mode: local only (SSH tunnel)${NC}"
            return 0
        fi

        # Cloudflare/Caddy requires DOMAIN
        if [ -z "$DOMAIN" ]; then
            if [ "$YES_MODE" = true ]; then
                echo -e "${RED}Error: --domain is required for --domain-type=$DOMAIN_TYPE${NC}" >&2
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
                echo -e "${RED}Error: Domain '$CLI_ROOT' — your Cloudflare token doesn't have access to this domain!${NC}" >&2
                echo "   Available domains: $AVAILABLE" >&2
                echo "   To add this domain, run: ./local/setup-cloudflare.sh" >&2
                return 1
            fi
        fi

        echo -e "${GREEN}Domain: $DOMAIN (type: $DOMAIN_TYPE)${NC}"
        return 0
    fi

    # --yes mode without --domain-type = error
    if [ "$YES_MODE" = true ]; then
        echo -e "${RED}Error: --domain-type is required in --yes mode${NC}" >&2
        return 1
    fi

    # Interactive mode
    echo ""
    echo "How do you want to access the application?"
    echo ""

    echo "  1) Own domain via Cloudflare"
    echo "     Script will configure DNS automatically"
    echo "     Requires: ./local/setup-cloudflare.sh"
    echo ""

    echo "  2) Own domain via Caddy auto-HTTPS"
    echo "     Point your A record to the server IP, Caddy gets Let's Encrypt cert"
    echo "     No third-party service needed"
    echo ""

    echo "  3) Local only (SSH tunnel)"
    echo "     Access via: ssh -L $PORT:localhost:$PORT $SSH_ALIAS"
    echo "     No domain, ideal for admin panels"
    echo ""

    read -p "Choose option [1-3]: " DOMAIN_CHOICE

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
            echo -e "${GREEN}Selected: local only (SSH tunnel)${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
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
    echo "Enter the domain you want to use for $APP_NAME."
    echo "Make sure the A record points to your server IP."
    echo ""

    read -p "Domain (e.g. $APP_NAME.example.com): " FULL_DOMAIN

    if [ -z "$FULL_DOMAIN" ]; then
        echo -e "${RED}Domain cannot be empty${NC}"
        return 1
    fi

    export DOMAIN="$FULL_DOMAIN"
    echo ""
    echo -e "${GREEN}Selected: $DOMAIN${NC}"

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
        echo -e "${YELLOW}Cloudflare is not configured!${NC}"
        echo "   Run first: ./local/setup-cloudflare.sh"
        return 1
    fi

    echo ""
    echo -e "${GREEN}Cloudflare configured${NC}"
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
        echo -e "${RED}No configured domains in Cloudflare${NC}"
        return 1
    fi

    local FULL_DOMAIN=""

    # If <= 3 domains, show ready-made suggestions
    if [ "$DOMAIN_COUNT" -le 3 ]; then
        echo "Choose a domain for $APP_NAME:"
        echo ""

        local i=1
        for domain in "${DOMAINS[@]}"; do
            echo "  $i) $APP_NAME.$domain"
            ((i++))
        done
        echo ""
        echo "  Or type a custom domain (e.g. $APP_NAME.mydomain.com)"
        echo ""

        read -p "Choice [1-$DOMAIN_COUNT] or domain: " CHOICE

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
                echo -e "${RED}Error: Domain '$INPUT_ROOT' — your Cloudflare token doesn't have access to this domain!${NC}"
                echo "   Available domains: ${DOMAINS[*]}"
                echo ""
                echo "   To add this domain, run: ./local/setup-cloudflare.sh"
                return 1
            fi
        else
            echo -e "${RED}No domain provided${NC}"
            return 1
        fi
    else
        # More than 3 domains - old mode
        echo "Available domains:"
        local i=1
        for domain in "${DOMAINS[@]}"; do
            echo "  $i) $domain"
            ((i++))
        done
        echo ""

        read -p "Enter full domain (e.g. $APP_NAME.yourdomain.com): " FULL_DOMAIN
    fi

    if [ -z "$FULL_DOMAIN" ]; then
        echo -e "${RED}Domain cannot be empty${NC}"
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
        echo -e "${RED}Error: Domain '$INPUT_ROOT' — your Cloudflare token doesn't have access to this domain!${NC}"
        echo "   Available domains: ${DOMAINS[*]}"
        echo ""
        echo "   To add this domain, run: ./local/setup-cloudflare.sh"
        return 1
    fi

    export DOMAIN="$FULL_DOMAIN"
    echo ""
    echo -e "${GREEN}Selected: $DOMAIN${NC}"

    return 0
}

# =============================================================================
# HELPER: Domain configuration summary
# =============================================================================

show_domain_summary() {
    echo ""
    echo "Domain configuration:"
    echo "   Type:   $DOMAIN_TYPE"
    if [ "$DOMAIN_TYPE" = "local" ]; then
        echo "   Access: SSH tunnel"
    else
        echo "   Domain: $DOMAIN"
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
        echo -e "${BLUE}[dry-run] Configuring domain: $DOMAIN_TYPE / $DOMAIN${NC}"
        return 0
    fi

    # Local - nothing to do
    if [ "$DOMAIN_TYPE" = "local" ]; then
        echo ""
        echo "Access via SSH tunnel:"
        echo -e "   ${BLUE}ssh -L $PORT:localhost:$PORT $SSH_ALIAS${NC}"
        echo "   Then open: http://localhost:$PORT"
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

    echo -e "${RED}Unknown domain type: $DOMAIN_TYPE${NC}"
    return 1
}

configure_domain_caddy() {
    local PORT="$1"
    local SSH_ALIAS="$2"

    echo ""
    echo "Configuring HTTPS via Caddy (Let's Encrypt)..."

    # Domain validation (preventing Caddyfile/shell injection)
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
        echo -e "${RED}Invalid domain: $DOMAIN${NC}" >&2
        return 1
    fi

    # Check if this is a static site (look for /tmp/APP_webroot file, not domain_public_webroot)
    local WEBROOT=$(server_exec "ls /tmp/*_webroot 2>/dev/null | grep -v domain_public_webroot | head -1 | xargs cat 2>/dev/null" 2>/dev/null)

    if [ -n "$WEBROOT" ]; then
        # Static site (littlelink, etc.) - use file_server mode
        echo "   Detected static site: $WEBROOT"
        if server_exec "command -v sp-expose &>/dev/null && sp-expose '$DOMAIN' '$WEBROOT' static"; then
            echo -e "${GREEN}HTTPS configured (file_server)${NC}"
            # Remove marker (don't remove domain_public_webroot!)
            server_exec "ls /tmp/*_webroot 2>/dev/null | grep -v domain_public_webroot | xargs rm -f" 2>/dev/null
        else
            echo -e "${YELLOW}sp-expose not available${NC}"
        fi
    else
        # Docker app - use reverse_proxy
        if server_exec "command -v sp-expose &>/dev/null && sp-expose '$DOMAIN' '$PORT'" 2>/dev/null; then
            echo -e "${GREEN}HTTPS configured (reverse_proxy)${NC}"
        else
            # Check if domain is already in Caddyfile
            if server_exec "grep -q '$DOMAIN' /etc/caddy/Caddyfile 2>/dev/null"; then
                echo -e "${GREEN}HTTPS already configured in Caddy${NC}"
            else
                echo -e "${YELLOW}sp-expose not available${NC}"
            fi
        fi
    fi

    echo ""
    echo -e "${GREEN}Domain configured: https://$DOMAIN${NC}"
    echo ""
    echo "Make sure your DNS A record points to the server IP."

    return 0
}

configure_domain_cloudflare() {
    local PORT="$1"
    local SSH_ALIAS="$2"

    local REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    local DNS_SCRIPT="$REPO_ROOT/local/dns-add.sh"
    local OPTIMIZE_SCRIPT="$REPO_ROOT/local/setup-cloudflare-optimize.sh"

    echo ""
    echo "Configuring DNS in Cloudflare..."

    # Domain validation (preventing Caddyfile/shell injection)
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
        echo -e "${RED}Invalid domain: $DOMAIN${NC}" >&2
        return 1
    fi

    local DNS_OK=false
    if [ -f "$DNS_SCRIPT" ]; then
        if bash "$DNS_SCRIPT" "$DOMAIN" "$SSH_ALIAS"; then
            echo -e "${GREEN}DNS configured: $DOMAIN${NC}"
            DNS_OK=true
        else
            # Check if record already exists (dns-add.sh exits 0 when IP is the same)
            # So exit != 0 means a real error
            echo -e "${RED}DNS configuration failed!${NC}"
            echo "   Check manually: ./local/dns-add.sh $DOMAIN $SSH_ALIAS"
        fi
    else
        echo -e "${YELLOW}dns-add.sh not found${NC}"
    fi

    # Cloudflare settings optimization (SSL Full, cache, compression)
    if [ -f "$OPTIMIZE_SCRIPT" ]; then
        echo ""
        # Map APP_NAME to --app preset (if known)
        local CF_APP_FLAG=""
        case "${APP_NAME:-}" in
            wordpress) CF_APP_FLAG="--app=wordpress" ;;
            gateflow)  CF_APP_FLAG="--app=nextjs" ;;
        esac
        bash "$OPTIMIZE_SCRIPT" "$DOMAIN" $CF_APP_FLAG || echo -e "${YELLOW}Cloudflare optimization skipped${NC}"
    fi

    # Configure Caddy on server (even if DNS didn't need changes)
    echo ""
    echo "Configuring HTTPS (Caddy)..."

    local CADDY_OK=false

    # Make sure Caddy + sp-expose is on the server
    if ! server_exec "command -v sp-expose &>/dev/null" 2>/dev/null; then
        echo "   sp-expose not found — installing Caddy..."
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
        echo "   Detected static site: $WEBROOT"
        if server_exec "command -v sp-expose &>/dev/null && sp-expose '$DOMAIN' '$WEBROOT' static" 2>/dev/null; then
            echo -e "${GREEN}HTTPS configured (file_server)${NC}"
            CADDY_OK=true
            # Remove marker (don't remove domain_public_webroot!)
            server_exec "ls /tmp/*_webroot 2>/dev/null | grep -v domain_public_webroot | xargs rm -f" 2>/dev/null
        fi
    else
        # Docker app - use reverse_proxy
        if server_exec "command -v sp-expose &>/dev/null && sp-expose '$DOMAIN' '$PORT' proxy" 2>/dev/null; then
            echo -e "${GREEN}HTTPS configured (reverse_proxy)${NC}"
            CADDY_OK=true
        fi
    fi

    # Fallback: sp-expose may have refused because domain is already in Caddyfile — that's OK
    if [ "$CADDY_OK" = false ]; then
        if server_exec "grep -q '$DOMAIN' /etc/caddy/Caddyfile 2>/dev/null"; then
            echo -e "${GREEN}HTTPS already configured in Caddy${NC}"
            CADDY_OK=true
        fi
    fi

    if [ "$CADDY_OK" = false ]; then
        if server_exec "command -v sp-expose &>/dev/null" 2>/dev/null; then
            echo -e "${RED}sp-expose could not configure Caddy${NC}"
            echo "   Check manually: ssh $SSH_ALIAS 'cat /etc/caddy/Caddyfile'"
        else
            echo -e "${RED}Caddy / sp-expose not installed on the server${NC}"
            echo "   Install: ssh $SSH_ALIAS 'bash -s' < system/caddy-install.sh"
        fi
    fi

    # Make sure Caddy is running
    if [ "$CADDY_OK" = true ]; then
        if ! server_exec "systemctl is-active --quiet caddy" 2>/dev/null; then
            echo "   Starting Caddy..."
            server_exec "systemctl start caddy && systemctl enable caddy 2>/dev/null" 2>/dev/null
        fi
    fi

    # Summary
    echo ""
    if [ "$DNS_OK" = true ] && [ "$CADDY_OK" = true ]; then
        echo -e "${GREEN}Domain configured: https://$DOMAIN${NC}"
    elif [ "$CADDY_OK" = true ]; then
        echo -e "${YELLOW}Caddy OK, but DNS needs attention: https://$DOMAIN${NC}"
    elif [ "$DNS_OK" = true ]; then
        echo -e "${YELLOW}DNS OK, but Caddy needs configuration${NC}"
    else
        echo -e "${RED}Domain was not configured — DNS and Caddy need attention${NC}"
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
        echo -e "${BLUE}[dry-run] Waiting for domain: $DOMAIN${NC}"
        return 0
    fi

    echo ""
    echo "Waiting for $DOMAIN to start responding..."

    local START_TIME=$(date +%s)
    local SPINNER="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local SPINNER_IDX=0

    while true; do
        local CURRENT_TIME=$(date +%s)
        local ELAPSED=$((CURRENT_TIME - START_TIME))

        if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
            echo ""
            echo -e "${YELLOW}Timeout - domain is not responding yet${NC}"
            echo ""

            # DNS diagnostics
            echo "Diagnostics:"
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
                        echo -e "   ${GREEN}Cloudflare DNS: $CF_TYPE -> $CF_CONTENT (proxy: $CF_PROXIED)${NC}"
                    fi
                fi
            fi

            if [ -n "$DIG_RESULT" ]; then
                echo -e "   ${GREEN}DNS resolve: $DOMAIN -> $DIG_RESULT${NC}"
                if [ "$DOMAIN_TYPE" = "cloudflare" ]; then
                    echo "   The IP above is a Cloudflare edge IP (correct when proxy is ON)"
                fi
            elif [ "$CF_RECORD_OK" = true ]; then
                echo -e "   ${YELLOW}DNS: record exists in Cloudflare, but not propagating yet${NC}"
                echo "   Wait 2-5 minutes and check: dig +short $DOMAIN"
            else
                echo -e "   ${RED}DNS: no record — domain does not resolve${NC}"
                echo "   Check: ./local/dns-add.sh $DOMAIN ${SSH_ALIAS:-vps}"
            fi

            # Check HTTP (only when DNS resolves)
            if [ -n "$DIG_RESULT" ]; then
                local DIAG_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN" 2>/dev/null || echo "000")
                if [ "$DIAG_HTTP" = "000" ]; then
                    echo -e "   ${RED}HTTPS: no connection — SSL may not be ready${NC}"
                elif [ "$DIAG_HTTP" = "521" ] || [ "$DIAG_HTTP" = "522" ] || [ "$DIAG_HTTP" = "523" ]; then
                    echo -e "   ${RED}HTTPS: HTTP $DIAG_HTTP — Cloudflare cannot reach the server (check Caddy)${NC}"
                elif [ "$DIAG_HTTP" -ge 500 ]; then
                    echo -e "   ${RED}HTTPS: HTTP $DIAG_HTTP — server error${NC}"
                else
                    echo -e "   ${YELLOW}HTTPS: HTTP $DIAG_HTTP${NC}"
                fi
            fi

            echo ""
            echo "   Check shortly: https://$DOMAIN"
            return 1
        fi

        # Check HTTP code
        local HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN" 2>/dev/null || echo "000")

        # Check HTTP 2xx-4xx (not 5xx)
        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 500 ]; then
            echo ""
            echo -e "${GREEN}Domain is working! (HTTP $HTTP_CODE)${NC}"
            return 0
        fi

        # Spinner
        local CHAR="${SPINNER:$SPINNER_IDX:1}"
        SPINNER_IDX=$(( (SPINNER_IDX + 1) % ${#SPINNER} ))
        printf "\r   %s Checking... (%ds/%ds)" "$CHAR" "$ELAPSED" "$TIMEOUT"

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
    echo "Domain configuration for: $APP_NAME"

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
