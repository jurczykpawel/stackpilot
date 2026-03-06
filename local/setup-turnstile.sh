#!/bin/bash

# StackPilot - Turnstile Setup
# Automatically configures Cloudflare Turnstile (CAPTCHA) for applications.
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/setup-turnstile.sh <domain> [ssh_alias]
#
# Examples:
#   ./local/setup-turnstile.sh app.example.com vps
#   ./local/setup-turnstile.sh myapp.example.com

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors must be defined BEFORE sourcing server-exec.sh (which loads i18n)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

source "$SCRIPT_DIR/../lib/server-exec.sh"

_TS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_TS_DIR/../lib/i18n.sh"
fi

DOMAIN="$1"
SSH_ALIAS="${2:-vps}"

# Configuration
CONFIG_DIR="$HOME/.config/cloudflare"
CONFIG_FILE="$CONFIG_DIR/config"
TURNSTILE_TOKEN_FILE="$CONFIG_DIR/turnstile_token"
TURNSTILE_ACCOUNT_FILE="$CONFIG_DIR/turnstile_account_id"

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <domain> [ssh_alias]"
    echo ""
    echo "Examples:"
    echo "  $0 app.example.com vps"
    echo "  $0 myapp.example.com"
    exit 1
fi

echo ""
msg "$MSG_TS_HEADER"
msg "$MSG_TS_DOMAIN" "$DOMAIN"
echo ""

# =============================================================================
# 1. CHECK EXISTING TOKEN
# =============================================================================

get_account_id() {
    local TOKEN="$1"

    # Get account ID from any zone
    if [ -f "$CONFIG_FILE" ]; then
        local ZONE_ID=$(grep "\.pl=\|\.com=\|\.dev=\|\.org=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2)
        if [ -n "$ZONE_ID" ]; then
            curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json" | \
                grep -o '"account":{[^}]*}' | grep -o '"id":"[^"]*"' | cut -d'"' -f4
        fi
    fi
}

check_turnstile_access() {
    local TOKEN="$1"
    local ACCOUNT_ID="$2"

    RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/challenges/widgets" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")

    if echo "$RESPONSE" | grep -q '"success":true'; then
        return 0
    else
        return 1
    fi
}

# Check if we have a token with Turnstile permissions
TURNSTILE_TOKEN=""
ACCOUNT_ID=""

# Try to load saved data
if [ -f "$TURNSTILE_TOKEN_FILE" ]; then
    TURNSTILE_TOKEN=$(cat "$TURNSTILE_TOKEN_FILE")
fi
if [ -f "$TURNSTILE_ACCOUNT_FILE" ]; then
    ACCOUNT_ID=$(cat "$TURNSTILE_ACCOUNT_FILE")
fi

# Verify saved token
if [ -n "$TURNSTILE_TOKEN" ] && [ -n "$ACCOUNT_ID" ]; then
    msg "$MSG_TS_TOKEN_FOUND"
    if check_turnstile_access "$TURNSTILE_TOKEN" "$ACCOUNT_ID"; then
        msg "$MSG_TS_TOKEN_OK"
    else
        msg "$MSG_TS_TOKEN_EXPIRED"
        TURNSTILE_TOKEN=""
        ACCOUNT_ID=""
        rm -f "$TURNSTILE_TOKEN_FILE" "$TURNSTILE_ACCOUNT_FILE"
    fi
fi

# If no dedicated token, try the main one
if [ -z "$TURNSTILE_TOKEN" ] && [ -f "$CONFIG_FILE" ]; then
    MAIN_TOKEN=$(grep "^API_TOKEN=" "$CONFIG_FILE" | cut -d= -f2)
    if [ -n "$MAIN_TOKEN" ]; then
        ACCOUNT_ID=$(get_account_id "$MAIN_TOKEN")
        if [ -n "$ACCOUNT_ID" ] && check_turnstile_access "$MAIN_TOKEN" "$ACCOUNT_ID"; then
            TURNSTILE_TOKEN="$MAIN_TOKEN"
            msg "$MSG_TS_MAIN_TOKEN_OK"
            # Save Account ID for future use
            mkdir -p "$CONFIG_DIR"
            echo "$ACCOUNT_ID" > "$TURNSTILE_ACCOUNT_FILE"
            chmod 600 "$TURNSTILE_ACCOUNT_FILE"
        fi
    fi
fi

# =============================================================================
# 2. IF NO TOKEN - ASK FOR A NEW ONE
# =============================================================================

if [ -z "$TURNSTILE_TOKEN" ] || [ -z "$ACCOUNT_ID" ]; then
    echo ""
    msg "$MSG_TS_NO_TOKEN"
    echo ""
    msg "$MSG_TS_NEED_PERM"
    echo ""
    msg "$MSG_TS_STEPS"
    msg "$MSG_TS_STEP1"
    msg "$MSG_TS_STEP2"
    msg "$MSG_TS_STEP3"
    msg "$MSG_TS_STEP4"
    msg "$MSG_TS_STEP5"
    msg "$MSG_TS_STEP6"
    msg "$MSG_TS_STEP7"
    msg "$MSG_TS_STEP8"
    msg "$MSG_TS_STEP9"
    echo ""

    read -p "$(msg_n "$MSG_TS_PRESS_ENTER")" _

    # Open browser
    if command -v open &>/dev/null; then
        open "https://dash.cloudflare.com/profile/api-tokens"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "https://dash.cloudflare.com/profile/api-tokens"
    fi

    echo ""
    read -p "$(msg_n "$MSG_TS_PASTE_TOKEN")" TURNSTILE_TOKEN

    if [ -z "$TURNSTILE_TOKEN" ]; then
        msg "$MSG_TS_TOKEN_EMPTY"
        exit 1
    fi

    # Get account ID
    echo ""
    msg "$MSG_TS_VERIFYING"

    # First try to get Account ID from the main CF token (has Zone permissions)
    if [ -z "$ACCOUNT_ID" ] && [ -f "$CONFIG_FILE" ]; then
        MAIN_TOKEN=$(grep "^API_TOKEN=" "$CONFIG_FILE" | cut -d= -f2)
        if [ -n "$MAIN_TOKEN" ]; then
            ACCOUNT_ID=$(get_account_id "$MAIN_TOKEN")
        fi
    fi

    # If still missing - try from the new token (requires Account:Read)
    if [ -z "$ACCOUNT_ID" ]; then
        ACCOUNTS_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
            -H "Authorization: Bearer $TURNSTILE_TOKEN" \
            -H "Content-Type: application/json")

        if echo "$ACCOUNTS_RESPONSE" | grep -q '"success":true'; then
            ACCOUNT_ID=$(echo "$ACCOUNTS_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        fi
    fi

    # Last resort - ask the user
    if [ -z "$ACCOUNT_ID" ]; then
        echo ""
        msg "$MSG_TS_NO_ACCOUNT"
        msg "$MSG_TS_ACCOUNT_HINT"
        echo ""
        read -p "$(msg_n "$MSG_TS_PASTE_ACCOUNT")" ACCOUNT_ID

        if [ -z "$ACCOUNT_ID" ]; then
            msg "$MSG_TS_ACCOUNT_REQUIRED"
            exit 1
        fi
    fi

    # Check Turnstile permissions
    if ! check_turnstile_access "$TURNSTILE_TOKEN" "$ACCOUNT_ID"; then
        msg "$MSG_TS_NO_TURNSTILE_PERM"
        msg "$MSG_TS_NO_PERM_HINT"
        exit 1
    fi

    msg "$MSG_TS_TOKEN_VERIFIED"

    # Save token and Account ID
    mkdir -p "$CONFIG_DIR"
    echo "$TURNSTILE_TOKEN" > "$TURNSTILE_TOKEN_FILE"
    echo "$ACCOUNT_ID" > "$TURNSTILE_ACCOUNT_FILE"
    chmod 600 "$TURNSTILE_TOKEN_FILE" "$TURNSTILE_ACCOUNT_FILE"
    msg "$MSG_TS_TOKEN_SAVED"
fi

# =============================================================================
# 3. CHECK IF WIDGET ALREADY EXISTS
# =============================================================================

echo ""
msg "$MSG_TS_CHECK_WIDGETS"

WIDGETS_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/challenges/widgets" \
    -H "Authorization: Bearer $TURNSTILE_TOKEN" \
    -H "Content-Type: application/json")

# Parse widgets via Python to properly handle JSON
MATCHING_WIDGETS=$(echo "$WIDGETS_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'result' in data:
        for widget in data['result']:
            domains = widget.get('domains', [])
            if '$DOMAIN' in domains:
                print(json.dumps({
                    'sitekey': widget.get('sitekey'),
                    'name': widget.get('name'),
                    'domains': domains,
                    'mode': widget.get('mode')
                }))
except Exception as e:
    pass
" 2>/dev/null)

if [ -n "$MATCHING_WIDGETS" ]; then
    # Count how many widgets match
    WIDGET_COUNT=$(echo "$MATCHING_WIDGETS" | wc -l | xargs)

    msg "$MSG_TS_FOUND_WIDGETS" "$WIDGET_COUNT" "$DOMAIN"
    echo ""

    # Display all found widgets
    WIDGET_NUM=1
    declare -a SITEKEYS

    while IFS= read -r widget_json; do
        WIDGET_NAME=$(echo "$widget_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('name', 'N/A'))")
        WIDGET_SITEKEY=$(echo "$widget_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('sitekey', ''))")
        WIDGET_MODE=$(echo "$widget_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('mode', 'N/A'))")

        SITEKEYS[$WIDGET_NUM]="$WIDGET_SITEKEY"

        # Check if we have saved keys for this widget
        KEYS_FILE="$CONFIG_DIR/turnstile_keys_${WIDGET_SITEKEY}"
        HAS_KEYS=""
        if [ -f "$KEYS_FILE" ]; then
            HAS_KEYS=" $(msg_n "$MSG_TS_KEYS_SAVED")"
        fi

        echo "  ${WIDGET_NUM}) Name: $WIDGET_NAME"
        echo "     Site Key: $WIDGET_SITEKEY"
        echo -e "     Mode: $WIDGET_MODE$HAS_KEYS"
        echo ""

        WIDGET_NUM=$((WIDGET_NUM + 1))
    done <<< "$MATCHING_WIDGETS"

    msg "$MSG_TS_OPTIONS"
    msg "$MSG_TS_OPT_USE" "$WIDGET_COUNT"
    msg "$MSG_TS_OPT_NEW"
    msg "$MSG_TS_OPT_DELETE"
    msg "$MSG_TS_OPT_QUIT"
    echo ""
    read -p "$(msg_n "$MSG_TS_CHOOSE")" WIDGET_CHOICE

    case "$WIDGET_CHOICE" in
        [1-9]*)
            # Check if number is in range
            if [ "$WIDGET_CHOICE" -ge 1 ] && [ "$WIDGET_CHOICE" -le "$WIDGET_COUNT" ]; then
                SITE_KEY="${SITEKEYS[$WIDGET_CHOICE]}"

                # Check if we have saved keys
                KEYS_FILE="$CONFIG_DIR/turnstile_keys_${SITE_KEY}"
                if [ -f "$KEYS_FILE" ]; then
                    msg "$MSG_TS_USING_WIDGET" "$SITE_KEY"
                    source "$KEYS_FILE"
                    echo "   Site Key: $CLOUDFLARE_TURNSTILE_SITE_KEY"
                    echo "   Secret Key: ${CLOUDFLARE_TURNSTILE_SECRET_KEY:0:20}..."
                    echo ""
                    msg "$MSG_TS_DONE"

                    # Also save under domain name for compatibility
                    DOMAIN_KEYS_FILE="$CONFIG_DIR/turnstile_keys_$DOMAIN"
                    cp "$KEYS_FILE" "$DOMAIN_KEYS_FILE"

                    exit 0
                else
                    echo ""
                    msg "$MSG_TS_NO_SECRET"
                    echo ""
                    msg "$MSG_TS_SECRET_VISIBLE"
                    msg "$MSG_TS_SECRET_OPTIONS"
                    msg "$MSG_TS_SECRET_OPT1"
                    msg "$MSG_TS_SECRET_OPT2"
                    echo ""
                    read -p "$(msg_n "$MSG_TS_MANUAL_KEY")" MANUAL_KEY

                    if [[ "$MANUAL_KEY" =~ ^[TtYy]$ ]]; then
                        read -p "$(msg_n "$MSG_TS_PASTE_SECRET")" SECRET_KEY
                        if [ -n "$SECRET_KEY" ]; then
                            # Save keys
                            echo "CLOUDFLARE_TURNSTILE_SITE_KEY=$SITE_KEY" > "$KEYS_FILE"
                            echo "CLOUDFLARE_TURNSTILE_SECRET_KEY=$SECRET_KEY" >> "$KEYS_FILE"
                            chmod 600 "$KEYS_FILE"

                            # Also save under domain name
                            DOMAIN_KEYS_FILE="$CONFIG_DIR/turnstile_keys_$DOMAIN"
                            cp "$KEYS_FILE" "$DOMAIN_KEYS_FILE"

                            msg "$MSG_TS_KEYS_SAVED_OK"
                            msg "$MSG_TS_DONE"
                            exit 0
                        fi
                    fi

                    echo ""
                    msg "$MSG_TS_RETRY_HINT"
                    exit 0
                fi
            else
                msg "$MSG_TS_INVALID"
                exit 1
            fi
            ;;
        [dD])
            echo ""
            msg "$MSG_TS_DELETE_WHICH"
            read -p "$(msg_n "$MSG_TS_DELETE_NUM" "$WIDGET_COUNT")" DELETE_NUM

            if [ "$DELETE_NUM" -ge 1 ] && [ "$DELETE_NUM" -le "$WIDGET_COUNT" ]; then
                SITE_KEY="${SITEKEYS[$DELETE_NUM]}"

                echo ""
                msg "$MSG_TS_DELETE_WARN"
                echo ""
                read -p "$(msg_n "$MSG_TS_DELETE_CONFIRM" "$SITE_KEY")" CONFIRM_DELETE

                if [[ "$CONFIRM_DELETE" =~ ^[TtYy]$ ]]; then
                    msg "$MSG_TS_DELETING"
                    DELETE_RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/challenges/widgets/$SITE_KEY" \
                        -H "Authorization: Bearer $TURNSTILE_TOKEN" \
                        -H "Content-Type: application/json")

                    if echo "$DELETE_RESPONSE" | grep -q '"success":true'; then
                        msg "$MSG_TS_DELETED"

                        # Remove saved keys
                        rm -f "$CONFIG_DIR/turnstile_keys_${SITE_KEY}" "$CONFIG_DIR/turnstile_keys_$DOMAIN"

                        # Continue to creating a new widget (no exit)
                    else
                        msg "$MSG_TS_DELETE_FAIL"
                        exit 1
                    fi
                else
                    exit 0
                fi
            else
                msg "$MSG_TS_INVALID"
                exit 1
            fi
            ;;
        [nN])
            echo ""
            msg "$MSG_TS_NEW_WIDGET"
            # Continue to widget creation section
            ;;
        [qQ])
            msg "$MSG_TS_CANCELLED"
            exit 0
            ;;
        *)
            msg "$MSG_TS_INVALID"
            exit 1
            ;;
    esac
fi

# =============================================================================
# 4. CREATE NEW WIDGET
# =============================================================================

echo ""
msg "$MSG_TS_CREATING" "$DOMAIN"

CREATE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/challenges/widgets" \
    -H "Authorization: Bearer $TURNSTILE_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{
        \"name\": \"$DOMAIN\",
        \"domains\": [\"$DOMAIN\"],
        \"mode\": \"managed\",
        \"bot_fight_mode\": false,
        \"clearance_level\": \"no_clearance\"
    }")

if echo "$CREATE_RESPONSE" | grep -q '"success":true'; then
    SITE_KEY=$(echo "$CREATE_RESPONSE" | grep -o '"sitekey":"[^"]*"' | cut -d'"' -f4)
    SECRET_KEY=$(echo "$CREATE_RESPONSE" | grep -o '"secret":"[^"]*"' | cut -d'"' -f4)

    msg "$MSG_TS_WIDGET_CREATED"
    echo ""
    msg "$MSG_TS_SEPARATOR"
    echo "   CLOUDFLARE_TURNSTILE_SITE_KEY=$SITE_KEY"
    echo "   CLOUDFLARE_TURNSTILE_SECRET_KEY=$SECRET_KEY"
    msg "$MSG_TS_SEPARATOR"
    echo ""

    # Save keys to file (for deploy.sh)
    # Save both under domain name and Site Key for easier lookup
    KEYS_FILE_DOMAIN="$CONFIG_DIR/turnstile_keys_$DOMAIN"
    KEYS_FILE_SITEKEY="$CONFIG_DIR/turnstile_keys_${SITE_KEY}"

    echo "CLOUDFLARE_TURNSTILE_SITE_KEY=$SITE_KEY" > "$KEYS_FILE_DOMAIN"
    echo "CLOUDFLARE_TURNSTILE_SECRET_KEY=$SECRET_KEY" >> "$KEYS_FILE_DOMAIN"
    chmod 600 "$KEYS_FILE_DOMAIN"

    # Copy for Site Key (to find it on reuse)
    cp "$KEYS_FILE_DOMAIN" "$KEYS_FILE_SITEKEY"
    chmod 600 "$KEYS_FILE_SITEKEY"

    msg "$MSG_TS_KEYS_FILE" "$KEYS_FILE_DOMAIN"

    # Add to .env.local on the server (if SSH_ALIAS was provided)
    if [ -n "$SSH_ALIAS" ]; then
        echo ""
        msg "$MSG_TS_UPLOAD_KEYS" "$SSH_ALIAS"

        # Determine paths based on domain (multi-instance support)
        # New location: /opt/stacks/sellf*
        INSTANCE_NAME="${DOMAIN%%.*}"
        SELLF_DIR="/opt/stacks/sellf-${INSTANCE_NAME}"
        PM2_NAME="sellf-${INSTANCE_NAME}"

        # Check if instance directory exists, if not - search further
        if ! server_exec "test -d $SELLF_DIR" 2>/dev/null; then
            SELLF_DIR="/opt/stacks/sellf"
            PM2_NAME="sellf"
        fi
        # Fallback to old location
        if ! server_exec "test -d $SELLF_DIR" 2>/dev/null; then
            SELLF_DIR="/root/sellf-${INSTANCE_NAME}"
            PM2_NAME="sellf-${INSTANCE_NAME}"
        fi
        if ! server_exec "test -d $SELLF_DIR" 2>/dev/null; then
            SELLF_DIR="/root/sellf"
            PM2_NAME="sellf"
        fi

        ENV_FILE="$SELLF_DIR/admin-panel/.env.local"
        STANDALONE_ENV="$SELLF_DIR/admin-panel/.next/standalone/admin-panel/.env.local"

        # Check if it exists
        if server_exec "test -f $ENV_FILE" 2>/dev/null; then
            # Add to main .env.local (with TURNSTILE_SECRET_KEY alias for Supabase)
            server_exec "echo '' >> $ENV_FILE && echo '# Cloudflare Turnstile' >> $ENV_FILE && echo 'CLOUDFLARE_TURNSTILE_SITE_KEY=$SITE_KEY' >> $ENV_FILE && echo 'CLOUDFLARE_TURNSTILE_SECRET_KEY=$SECRET_KEY' >> $ENV_FILE && echo 'TURNSTILE_SECRET_KEY=$SECRET_KEY' >> $ENV_FILE"

            # Copy to standalone
            server_exec "cp $ENV_FILE $STANDALONE_ENV 2>/dev/null || true"

            msg "$MSG_TS_KEYS_ADDED"

            # Restart PM2 with environment variable reload
            msg "$MSG_TS_RESTARTING"

            STANDALONE_DIR="$SELLF_DIR/admin-panel/.next/standalone/admin-panel"
            # IMPORTANT: use --interpreter node, NOT 'node server.js' in quotes (bash doesn't inherit env)
            RESTART_CMD="export PATH=\"\$HOME/.bun/bin:\$PATH\" && pm2 delete $PM2_NAME 2>/dev/null; cd $STANDALONE_DIR && unset HOSTNAME && set -a && source .env.local && set +a && export PORT=\${PORT:-3333} && export HOSTNAME=\${HOSTNAME:-::} && pm2 start server.js --name $PM2_NAME --interpreter node && pm2 save"

            if server_exec "$RESTART_CMD" 2>/dev/null; then
                msg "$MSG_TS_RESTART_OK"
            else
                msg "$MSG_TS_RESTART_FAIL" "$PM2_NAME"
            fi
        else
            msg "$MSG_TS_NO_ENV"
        fi
    fi

    # =============================================================================
    # 5. CAPTCHA CONFIGURATION IN SUPABASE AUTH
    # =============================================================================

    # Check if we have Supabase configuration
    SUPABASE_TOKEN_FILE="$HOME/.config/supabase/access_token"
    SELLF_CONFIG="$HOME/.config/stackpilot/sellf/supabase.env"

    if [ -f "$SUPABASE_TOKEN_FILE" ] && [ -f "$SELLF_CONFIG" ]; then
        echo ""
        msg "$MSG_TS_SUPABASE_CONFIG"

        SUPABASE_TOKEN=$(cat "$SUPABASE_TOKEN_FILE")
        source "$SELLF_CONFIG"  # Loads PROJECT_REF

        if [ -n "$SUPABASE_TOKEN" ] && [ -n "$PROJECT_REF" ]; then
            CAPTCHA_CONFIG=$(cat <<EOF
{
    "security_captcha_enabled": true,
    "security_captcha_provider": "turnstile",
    "security_captcha_secret": "$SECRET_KEY"
}
EOF
)
            RESPONSE=$(curl -s -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
                -H "Authorization: Bearer $SUPABASE_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$CAPTCHA_CONFIG")

            if echo "$RESPONSE" | grep -q '"error"'; then
                msg "$MSG_TS_SUPABASE_FAIL"
            else
                msg "$MSG_TS_SUPABASE_OK"
            fi
        fi
    else
        echo ""
        msg "$MSG_TS_SUPABASE_MANUAL"
        msg "$MSG_TS_SUPABASE_ALT"
    fi

    echo ""
    msg "$MSG_TS_DONE"
else
    ERROR=$(echo "$CREATE_RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
    msg "$MSG_TS_CREATE_FAIL" "$ERROR"
    echo ""
    msg "$MSG_TS_FULL_RESPONSE"
    echo "$CREATE_RESPONSE" | head -c 500
    exit 1
fi
