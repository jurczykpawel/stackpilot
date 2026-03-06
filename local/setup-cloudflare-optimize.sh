#!/bin/bash

# StackPilot - Cloudflare Optimization
# Sets optimal Cloudflare settings for domains on the VPS
# Author: Paweł (Lazy Engineer)
#
# Zone settings (universal):
#   - SSL: Full (Caddy auto-generates certificate via Let's Encrypt)
#   - Brotli: ON
#   - Always HTTPS: ON
#   - Minimum TLS: 1.2
#   - Early Hints: ON
#   - HTTP/2, HTTP/3
#
# Cache Rules (--app):
#   wordpress: bypass wp-admin/wp-login/wp-json, cache wp-content/wp-includes
#   nextjs:    cache /_next/static/*, bypass /api/*
#
# Rules are scoped per hostname and merged with existing ones.
# Running multiple times is safe (overwrites rules only for the given host).

set -e

_CFO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_CFO_DIR/../lib/i18n.sh"
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
NC="${NC:-\033[0m}"

CONFIG_FILE="$HOME/.config/cloudflare/config"

# Parse arguments
FULL_DOMAIN=""
APP_TYPE=""

for arg in "$@"; do
    case "$arg" in
        --app=*) APP_TYPE="${arg#--app=}" ;;
        -*)
            msg "$MSG_CFO_UNKNOWN_APP" "$arg"
            exit 1
            ;;
        *) FULL_DOMAIN="$arg" ;;
    esac
done

if [ -z "$FULL_DOMAIN" ]; then
    echo "Usage: $0 <domain> [--app=wordpress|nextjs]"
    echo ""
    echo "Optimizes Cloudflare settings for a domain:"
    echo "  - SSL Full (Caddy auto-cert)"
    echo "  - Brotli compression"
    echo "  - Always HTTPS, HTTP/2, HTTP/3"
    echo "  - Early Hints"
    echo ""
    echo "Cache Rules (optional, requires --app):"
    echo "  --app=wordpress   Bypass wp-admin/wp-login, cache WP static assets"
    echo "  --app=nextjs      Cache /_next/static/*, bypass /api/*"
    echo ""
    echo "Rules are scoped per hostname - safe for multiple apps on one domain."
    echo ""
    echo "Examples:"
    echo "  $0 app.mydomain.com"
    echo "  $0 wp.mydomain.com --app=wordpress"
    echo "  $0 next.mydomain.com --app=nextjs"
    echo ""
    echo "Requires: ./local/setup-cloudflare.sh"
    exit 1
fi

# Validate --app
if [ -n "$APP_TYPE" ] && [ "$APP_TYPE" != "wordpress" ] && [ "$APP_TYPE" != "nextjs" ]; then
    msg "$MSG_CFO_UNKNOWN_APP" "$APP_TYPE"
    msg "$MSG_CFO_APP_AVAIL"
    exit 1
fi

# Check configuration
if [ ! -f "$CONFIG_FILE" ]; then
    msg "$MSG_CFO_NO_CONFIG"
    msg "$MSG_CFO_NO_CONFIG_HINT"
    exit 1
fi

# Extract token (don't source the whole file - contains zone mappings with dots)
CF_API_TOKEN=$(grep -E "^(CF_)?API_TOKEN=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2)

if [ -z "$CF_API_TOKEN" ]; then
    msg "$MSG_CFO_NO_TOKEN"
    exit 1
fi

# Extract root domain (zone)
# app.example.com → example.com
ZONE_NAME=$(echo "$FULL_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')

msg "$MSG_CFO_HEADER"
msg "$MSG_CFO_DOMAIN" "$FULL_DOMAIN"
msg "$MSG_CFO_ZONE" "$ZONE_NAME"
if [ -n "$APP_TYPE" ]; then
    msg "$MSG_CFO_APP" "$APP_TYPE"
fi
echo ""

# Get Zone ID
msg "$MSG_CFO_ZONE_LOOKUP"
ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json")

ZONE_ID=$(echo "$ZONE_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$ZONE_ID" ]; then
    msg "$MSG_CFO_ZONE_NOT_FOUND" "$ZONE_NAME"
    msg "$MSG_CFO_ZONE_NOT_FOUND_HINT"
    exit 1
fi

msg "$MSG_CFO_ZONE_ID" "$ZONE_ID"
echo ""

# Track permission errors
PERMISSION_ERRORS=0

# Function to set zone options
set_zone_setting() {
    local SETTING="$1"
    local VALUE="$2"
    local DISPLAY_NAME="$3"

    echo -n "   $DISPLAY_NAME... "

    RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/$SETTING" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"value\":$VALUE}")

    if echo "$RESPONSE" | grep -q '"success":true'; then
        echo -e "${GREEN}✅${NC}"
    else
        ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo -e "${YELLOW}⚠️  $ERROR${NC}"
        if echo "$ERROR" | grep -qi "unauthorized\|authentication"; then
            PERMISSION_ERRORS=$((PERMISSION_ERRORS + 1))
        fi
    fi
}

# =============================================================================
# ZONE SETTINGS
# =============================================================================

msg "$MSG_CFO_ZONE_SETTINGS"

# SSL Full - Caddy auto-generates certificate (Let's Encrypt)
# Don't use Flexible — it breaks other subdomains/servers in the same zone
set_zone_setting "ssl" '"full"' "SSL Full"

# Brotli - better compression
set_zone_setting "brotli" '"on"' "Brotli"

# Always HTTPS
set_zone_setting "always_use_https" '"on"' "Always HTTPS"

# Minimum TLS 1.2
set_zone_setting "min_tls_version" '"1.2"' "Min TLS 1.2"

# Early Hints - faster loading
set_zone_setting "early_hints" '"on"' "Early Hints"

# HTTP/2
set_zone_setting "http2" '"on"' "HTTP/2"

# HTTP/3 (QUIC)
set_zone_setting "http3" '"on"' "HTTP/3"

echo ""

# =============================================================================
# CACHE RULES (depends on --app, scoped per hostname, merged)
# =============================================================================

# Generate cache rules per app type (without hostname - added later via jq)
get_wordpress_rules() {
    cat <<'RULES'
[
    {
      "expression": "(http.request.uri.path matches \"^/wp-admin/.*\" or http.request.uri.path eq \"/wp-login.php\" or http.request.uri.path matches \"^/wp-json/.*\" or http.request.uri.path eq \"/wp-cron.php\" or http.request.uri.path eq \"/xmlrpc.php\")",
      "description": "Bypass cache for WordPress admin/API",
      "action": "set_cache_settings",
      "action_parameters": {
        "cache": false
      }
    },
    {
      "expression": "(not http.request.uri.path matches \"^/wp-\" and http.request.method eq \"GET\" and not http.cookie contains \"wordpress_logged_in\" and not http.cookie contains \"woocommerce_cart_hash\")",
      "description": "Cache WordPress HTML pages on CF edge (24h)",
      "action": "set_cache_settings",
      "action_parameters": {
        "cache": true,
        "edge_ttl": {
          "mode": "override_origin",
          "default": 86400
        },
        "browser_ttl": {
          "mode": "override_origin",
          "default": 300
        }
      }
    },
    {
      "expression": "(http.request.uri.path matches \"^/wp-content/uploads/.*\" or http.request.uri.path matches \"^/wp-includes/.*\")",
      "description": "Cache WordPress media and core static (1 year)",
      "action": "set_cache_settings",
      "action_parameters": {
        "edge_ttl": {
          "mode": "override_origin",
          "default": 31536000
        },
        "browser_ttl": {
          "mode": "override_origin",
          "default": 31536000
        }
      }
    },
    {
      "expression": "(http.request.uri.path matches \"^/wp-content/themes/.*\" or http.request.uri.path matches \"^/wp-content/plugins/.*\")",
      "description": "Cache WordPress themes/plugins assets (1 week)",
      "action": "set_cache_settings",
      "action_parameters": {
        "edge_ttl": {
          "mode": "override_origin",
          "default": 604800
        },
        "browser_ttl": {
          "mode": "override_origin",
          "default": 604800
        }
      }
    }
]
RULES
}

get_nextjs_rules() {
    cat <<'RULES'
[
    {
      "expression": "(http.request.uri.path matches \"^/_next/static/.*\")",
      "description": "Cache Next.js static assets (1 year)",
      "action": "set_cache_settings",
      "action_parameters": {
        "edge_ttl": {
          "mode": "override_origin",
          "default": 31536000
        },
        "browser_ttl": {
          "mode": "override_origin",
          "default": 31536000
        }
      }
    },
    {
      "expression": "(http.request.uri.path matches \"^/api/.*\")",
      "description": "Bypass cache for API routes",
      "action": "set_cache_settings",
      "action_parameters": {
        "cache": false
      }
    }
]
RULES
}

# Scope rules per hostname and tag in description
# Input: JSON rules array (stdin), $1 = hostname
scope_rules_to_host() {
    local HOST="$1"
    jq --arg host "$HOST" '
        map(
            .expression = "http.host eq \"" + $host + "\" and " + .expression |
            .description = .description + " [" + $host + "]"
        )
    '
}

CACHE_RULE_OK=false

if [ -n "$APP_TYPE" ]; then
    msg "$MSG_CFO_CACHE_RULES" "$APP_TYPE" "$FULL_DOMAIN"

    # Check jq (required for rule merging)
    if ! command -v jq &>/dev/null; then
        msg "$MSG_CFO_NO_JQ"
        msg "$MSG_CFO_NO_JQ_INSTALL"
        echo ""
    else
        # Get rules for selected app and scope per hostname
        case "$APP_TYPE" in
            wordpress) NEW_RULES=$(get_wordpress_rules | scope_rules_to_host "$FULL_DOMAIN") ;;
            nextjs)    NEW_RULES=$(get_nextjs_rules | scope_rules_to_host "$FULL_DOMAIN") ;;
        esac

        # Check if ruleset already exists
        RULESETS_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets?phase=http_request_cache_settings" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json")

        RULESET_ID=$(echo "$RULESETS_RESPONSE" | jq -r '.result[0].id // empty')

        if [ -n "$RULESET_ID" ]; then
            # Get existing rules
            EXISTING_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$RULESET_ID" \
                -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json")

            # Remove old rules for this host, keep the rest
            KEPT_RULES=$(echo "$EXISTING_RESPONSE" | jq --arg host "$FULL_DOMAIN" '
                [.result.rules[] | select(.description | endswith("[" + $host + "]") | not)]
            ')

            # Merge: existing (without this host) + new
            MERGED=$(jq -n --argjson kept "$KEPT_RULES" --argjson new "$NEW_RULES" '
                {"rules": ($kept + $new)}
            ')

            msg_n "$MSG_CFO_RULES_UPDATE"
            RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$RULESET_ID" \
                -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "$MERGED")
        else
            # Create new ruleset
            FULL_RULESET=$(jq -n --argjson rules "$NEW_RULES" '{
                "name": "StackPilot Cache Rules",
                "kind": "zone",
                "phase": "http_request_cache_settings",
                "rules": $rules
            }')

            msg_n "$MSG_CFO_RULES_CREATE"
            RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
                -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "$FULL_RULESET")
        fi

        if echo "$RESPONSE" | grep -q '"success":true'; then
            msg "$MSG_CFO_RULES_OK"
            CACHE_RULE_OK=true
            case "$APP_TYPE" in
                wordpress)
                    msg "$MSG_CFO_CACHE_WP_BYPASS"
                    msg "$MSG_CFO_CACHE_WP_UPLOADS"
                    msg "$MSG_CFO_CACHE_WP_THEMES"
                    ;;
                nextjs)
                    msg "$MSG_CFO_CACHE_NEXTJS_STATIC"
                    msg "$MSG_CFO_CACHE_NEXTJS_API"
                    ;;
            esac
        else
            ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
            if [ -n "$ERROR" ]; then
                msg "$MSG_CFO_RULES_FAIL" "$ERROR"
            else
                msg "$MSG_CFO_RULES_FAIL_GENERIC"
            fi
            if echo "$ERROR" | grep -qi "unauthorized\|authentication"; then
                PERMISSION_ERRORS=$((PERMISSION_ERRORS + 1))
            fi
        fi

        echo ""
    fi
else
    msg "$MSG_CFO_SKIP_CACHE"
    echo ""
fi

# Summary
if [ "$PERMISSION_ERRORS" -gt 0 ]; then
    msg "$MSG_CFO_PERM_ERRORS"
    echo ""
    msg "$MSG_CFO_PERM_FIX"
    msg "$MSG_CFO_PERM_ZONE_SETTINGS"
    if [ -n "$APP_TYPE" ]; then
        msg "$MSG_CFO_PERM_CACHE" "$APP_TYPE"
    fi
    echo ""
    msg "$MSG_CFO_PERM_LINK"
    msg "$MSG_CFO_PERM_MANUAL"
    msg "$MSG_CFO_PERM_SSL"
    msg "$MSG_CFO_PERM_BROTLI"
    echo ""
else
    msg "$MSG_CFO_DONE"
    echo ""
    msg "$MSG_CFO_SUMMARY"
    msg "$MSG_CFO_SUM_SSL"
    msg "$MSG_CFO_SUM_BROTLI"
    msg "$MSG_CFO_SUM_HTTPS"
    msg "$MSG_CFO_SUM_TLS"
    msg "$MSG_CFO_SUM_HTTP"
    msg "$MSG_CFO_SUM_HINTS"
    if [ "$CACHE_RULE_OK" = true ]; then
        case "$APP_TYPE" in
            wordpress)
                msg "$MSG_CFO_SUM_CACHE_WP1"
                msg "$MSG_CFO_SUM_CACHE_WP2"
                msg "$MSG_CFO_SUM_BYPASS_WP"
                ;;
            nextjs)
                msg "$MSG_CFO_SUM_CACHE_NJS"
                msg "$MSG_CFO_SUM_BYPASS_NJS"
                ;;
        esac
        msg "$MSG_CFO_SUM_SCOPE" "$FULL_DOMAIN"
    fi
fi
echo ""
