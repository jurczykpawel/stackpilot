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
source "$SCRIPT_DIR/../lib/server-exec.sh"

DOMAIN="$1"
SSH_ALIAS="${2:-vps}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
echo -e "${BLUE}🔒 Turnstile Setup${NC}"
echo "   Domain: $DOMAIN"
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
    echo "🔑 Found saved Turnstile token..."
    if check_turnstile_access "$TURNSTILE_TOKEN" "$ACCOUNT_ID"; then
        echo -e "${GREEN}   ✅ Token is current${NC}"
    else
        echo "   ⚠️  Token expired or is invalid"
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
            echo -e "${GREEN}✅ Main token has Turnstile permissions${NC}"
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
    echo -e "${YELLOW}⚠️  No token with Turnstile permissions${NC}"
    echo ""
    echo "An API token with permission: Account → Turnstile → Edit is required"
    echo ""
    echo "Step by step:"
    echo "   1. Open: https://dash.cloudflare.com/profile/api-tokens"
    echo "   2. Click 'Create Token'"
    echo "   3. Choose 'Create Custom Token'"
    echo "   4. Name: 'Turnstile API'"
    echo "   5. Permissions:"
    echo "      • Account → Turnstile → Edit"
    echo "   6. Account Resources: Include → All accounts (or choose specific)"
    echo "   7. Click 'Continue to summary' → 'Create Token'"
    echo "   8. Copy the token"
    echo ""

    read -p "Press Enter to open Cloudflare..." _

    # Open browser
    if command -v open &>/dev/null; then
        open "https://dash.cloudflare.com/profile/api-tokens"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "https://dash.cloudflare.com/profile/api-tokens"
    fi

    echo ""
    read -p "Paste Turnstile token: " TURNSTILE_TOKEN

    if [ -z "$TURNSTILE_TOKEN" ]; then
        echo -e "${RED}❌ Token cannot be empty${NC}"
        exit 1
    fi

    # Get account ID
    echo ""
    echo "🔍 Verifying token..."

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
        echo -e "${YELLOW}Cannot automatically retrieve Account ID.${NC}"
        echo "Find it at: https://dash.cloudflare.com → any domain → Overview → Account ID (right side)"
        echo ""
        read -p "Paste Account ID: " ACCOUNT_ID

        if [ -z "$ACCOUNT_ID" ]; then
            echo -e "${RED}❌ Account ID is required${NC}"
            exit 1
        fi
    fi

    # Check Turnstile permissions
    if ! check_turnstile_access "$TURNSTILE_TOKEN" "$ACCOUNT_ID"; then
        echo -e "${RED}❌ Token does not have Turnstile permissions${NC}"
        echo "   Make sure you added: Account → Turnstile → Edit"
        exit 1
    fi

    echo -e "${GREEN}✅ Token verified!${NC}"

    # Save token and Account ID
    mkdir -p "$CONFIG_DIR"
    echo "$TURNSTILE_TOKEN" > "$TURNSTILE_TOKEN_FILE"
    echo "$ACCOUNT_ID" > "$TURNSTILE_ACCOUNT_FILE"
    chmod 600 "$TURNSTILE_TOKEN_FILE" "$TURNSTILE_ACCOUNT_FILE"
    echo "   Token and Account ID saved"
fi

# =============================================================================
# 3. CHECK IF WIDGET ALREADY EXISTS
# =============================================================================

echo ""
echo "🔍 Checking existing Turnstile widgets..."

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

    echo -e "${YELLOW}⚠️  Found $WIDGET_COUNT widget(s) for domain $DOMAIN${NC}"
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
            HAS_KEYS=" ${GREEN}✓ Keys saved${NC}"
        fi

        echo -e "  ${WIDGET_NUM}) Name: $WIDGET_NAME"
        echo "     Site Key: $WIDGET_SITEKEY"
        echo "     Mode: $WIDGET_MODE$HAS_KEYS"
        echo ""

        WIDGET_NUM=$((WIDGET_NUM + 1))
    done <<< "$MATCHING_WIDGETS"

    echo "Options:"
    echo "  [1-$WIDGET_COUNT] Use existing widget"
    echo "  [n] Create new widget"
    echo "  [d] Delete selected widget and create new"
    echo "  [q] Cancel"
    echo ""
    read -p "Choose an option: " WIDGET_CHOICE

    case "$WIDGET_CHOICE" in
        [1-9]*)
            # Check if number is in range
            if [ "$WIDGET_CHOICE" -ge 1 ] && [ "$WIDGET_CHOICE" -le "$WIDGET_COUNT" ]; then
                SITE_KEY="${SITEKEYS[$WIDGET_CHOICE]}"

                # Check if we have saved keys
                KEYS_FILE="$CONFIG_DIR/turnstile_keys_${SITE_KEY}"
                if [ -f "$KEYS_FILE" ]; then
                    echo -e "${GREEN}✅ Using widget with Site Key: $SITE_KEY${NC}"
                    source "$KEYS_FILE"
                    echo "   Site Key: $CLOUDFLARE_TURNSTILE_SITE_KEY"
                    echo "   Secret Key: ${CLOUDFLARE_TURNSTILE_SECRET_KEY:0:20}..."
                    echo ""
                    echo -e "${GREEN}🎉 Turnstile configured!${NC}"

                    # Also save under domain name for compatibility
                    DOMAIN_KEYS_FILE="$CONFIG_DIR/turnstile_keys_$DOMAIN"
                    cp "$KEYS_FILE" "$DOMAIN_KEYS_FILE"

                    exit 0
                else
                    echo ""
                    echo -e "${YELLOW}⚠️  No saved Secret Key for this widget.${NC}"
                    echo ""
                    echo "Secret Key is only visible when creating the widget."
                    echo "You can:"
                    echo "  1. Enter Secret Key manually (if you have it)"
                    echo "  2. Delete the widget and create a new one"
                    echo ""
                    read -p "Enter Secret Key manually? [y/N]: " MANUAL_KEY

                    if [[ "$MANUAL_KEY" =~ ^[TtYy]$ ]]; then
                        read -p "Paste Secret Key: " SECRET_KEY
                        if [ -n "$SECRET_KEY" ]; then
                            # Save keys
                            echo "CLOUDFLARE_TURNSTILE_SITE_KEY=$SITE_KEY" > "$KEYS_FILE"
                            echo "CLOUDFLARE_TURNSTILE_SECRET_KEY=$SECRET_KEY" >> "$KEYS_FILE"
                            chmod 600 "$KEYS_FILE"

                            # Also save under domain name
                            DOMAIN_KEYS_FILE="$CONFIG_DIR/turnstile_keys_$DOMAIN"
                            cp "$KEYS_FILE" "$DOMAIN_KEYS_FILE"

                            echo -e "${GREEN}✅ Keys saved!${NC}"
                            echo -e "${GREEN}🎉 Turnstile configured!${NC}"
                            exit 0
                        fi
                    fi

                    echo ""
                    echo "Run this script again and choose option [d] to delete the widget and create a new one."
                    exit 0
                fi
            else
                echo -e "${RED}❌ Invalid choice${NC}"
                exit 1
            fi
            ;;
        [dD])
            echo ""
            echo "Which widget to delete?"
            read -p "Number [1-$WIDGET_COUNT]: " DELETE_NUM

            if [ "$DELETE_NUM" -ge 1 ] && [ "$DELETE_NUM" -le "$WIDGET_COUNT" ]; then
                SITE_KEY="${SITEKEYS[$DELETE_NUM]}"

                echo ""
                echo -e "${YELLOW}⚠️  WARNING: Deleting a widget will cause all applications using this Site Key to stop working!${NC}"
                echo ""
                read -p "Are you sure you want to delete widget $SITE_KEY? [y/N]: " CONFIRM_DELETE

                if [[ "$CONFIRM_DELETE" =~ ^[TtYy]$ ]]; then
                    echo "🗑️  Deleting widget..."
                    DELETE_RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/challenges/widgets/$SITE_KEY" \
                        -H "Authorization: Bearer $TURNSTILE_TOKEN" \
                        -H "Content-Type: application/json")

                    if echo "$DELETE_RESPONSE" | grep -q '"success":true'; then
                        echo -e "${GREEN}✅ Widget deleted${NC}"

                        # Remove saved keys
                        rm -f "$CONFIG_DIR/turnstile_keys_${SITE_KEY}" "$CONFIG_DIR/turnstile_keys_$DOMAIN"

                        # Continue to creating a new widget (no exit)
                    else
                        echo -e "${RED}❌ Failed to delete widget${NC}"
                        exit 1
                    fi
                else
                    exit 0
                fi
            else
                echo -e "${RED}❌ Invalid choice${NC}"
                exit 1
            fi
            ;;
        [nN])
            echo ""
            echo "Creating new widget..."
            # Continue to widget creation section
            ;;
        [qQ])
            echo "Cancelled."
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Invalid choice${NC}"
            exit 1
            ;;
    esac
fi

# =============================================================================
# 4. CREATE NEW WIDGET
# =============================================================================

echo ""
echo "🔧 Creating Turnstile widget for $DOMAIN..."

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

    echo -e "${GREEN}✅ Widget created!${NC}"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "   CLOUDFLARE_TURNSTILE_SITE_KEY=$SITE_KEY"
    echo "   CLOUDFLARE_TURNSTILE_SECRET_KEY=$SECRET_KEY"
    echo "════════════════════════════════════════════════════════════════"
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

    echo "💾 Keys saved in: $KEYS_FILE_DOMAIN"

    # Add to .env.local on the server (if SSH_ALIAS was provided)
    if [ -n "$SSH_ALIAS" ]; then
        echo ""
        echo "📤 Adding keys to server $SSH_ALIAS..."

        # Determine paths based on domain (multi-instance support)
        # New location: /opt/stacks/gateflow*
        INSTANCE_NAME="${DOMAIN%%.*}"
        GATEFLOW_DIR="/opt/stacks/gateflow-${INSTANCE_NAME}"
        PM2_NAME="gateflow-${INSTANCE_NAME}"

        # Check if instance directory exists, if not - search further
        if ! server_exec "test -d $GATEFLOW_DIR" 2>/dev/null; then
            GATEFLOW_DIR="/opt/stacks/gateflow"
            PM2_NAME="gateflow"
        fi
        # Fallback to old location
        if ! server_exec "test -d $GATEFLOW_DIR" 2>/dev/null; then
            GATEFLOW_DIR="/root/gateflow-${INSTANCE_NAME}"
            PM2_NAME="gateflow-${INSTANCE_NAME}"
        fi
        if ! server_exec "test -d $GATEFLOW_DIR" 2>/dev/null; then
            GATEFLOW_DIR="/root/gateflow"
            PM2_NAME="gateflow"
        fi

        ENV_FILE="$GATEFLOW_DIR/admin-panel/.env.local"
        STANDALONE_ENV="$GATEFLOW_DIR/admin-panel/.next/standalone/admin-panel/.env.local"

        # Check if it exists
        if server_exec "test -f $ENV_FILE" 2>/dev/null; then
            # Add to main .env.local (with TURNSTILE_SECRET_KEY alias for Supabase)
            server_exec "echo '' >> $ENV_FILE && echo '# Cloudflare Turnstile' >> $ENV_FILE && echo 'CLOUDFLARE_TURNSTILE_SITE_KEY=$SITE_KEY' >> $ENV_FILE && echo 'CLOUDFLARE_TURNSTILE_SECRET_KEY=$SECRET_KEY' >> $ENV_FILE && echo 'TURNSTILE_SECRET_KEY=$SECRET_KEY' >> $ENV_FILE"

            # Copy to standalone
            server_exec "cp $ENV_FILE $STANDALONE_ENV 2>/dev/null || true"

            echo -e "${GREEN}   ✅ Keys added${NC}"

            # Restart PM2 with environment variable reload
            echo "🔄 Restarting GateFlow..."

            STANDALONE_DIR="$GATEFLOW_DIR/admin-panel/.next/standalone/admin-panel"
            # IMPORTANT: use --interpreter node, NOT 'node server.js' in quotes (bash doesn't inherit env)
            RESTART_CMD="export PATH=\"\$HOME/.bun/bin:\$PATH\" && pm2 delete $PM2_NAME 2>/dev/null; cd $STANDALONE_DIR && unset HOSTNAME && set -a && source .env.local && set +a && export PORT=\${PORT:-3333} && export HOSTNAME=\${HOSTNAME:-::} && pm2 start server.js --name $PM2_NAME --interpreter node && pm2 save"

            if server_exec "$RESTART_CMD" 2>/dev/null; then
                echo -e "${GREEN}   ✅ Application restarted${NC}"
            else
                echo -e "${YELLOW}   ⚠️  Restart failed - do it manually: pm2 restart $PM2_NAME${NC}"
            fi
        else
            echo -e "${YELLOW}   ⚠️  .env.local not found - is GateFlow installed?${NC}"
        fi
    fi

    # =============================================================================
    # 5. CAPTCHA CONFIGURATION IN SUPABASE AUTH
    # =============================================================================

    # Check if we have Supabase configuration
    SUPABASE_TOKEN_FILE="$HOME/.config/supabase/access_token"
    GATEFLOW_CONFIG="$HOME/.config/gateflow/supabase.env"

    if [ -f "$SUPABASE_TOKEN_FILE" ] && [ -f "$GATEFLOW_CONFIG" ]; then
        echo ""
        echo "🔧 Configuring CAPTCHA in Supabase Auth..."

        SUPABASE_TOKEN=$(cat "$SUPABASE_TOKEN_FILE")
        source "$GATEFLOW_CONFIG"  # Loads PROJECT_REF

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
                echo -e "${YELLOW}   ⚠️  Failed to configure CAPTCHA in Supabase${NC}"
            else
                echo -e "${GREEN}   ✅ CAPTCHA enabled in Supabase Auth${NC}"
            fi
        fi
    else
        echo ""
        echo -e "${YELLOW}ℹ️  To enable CAPTCHA in Supabase, run deploy.sh again${NC}"
        echo "   or configure manually in Supabase Dashboard → Authentication → Captcha"
    fi

    echo ""
    echo -e "${GREEN}🎉 Turnstile configured!${NC}"
else
    ERROR=$(echo "$CREATE_RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
    echo -e "${RED}❌ Error: $ERROR${NC}"
    echo ""
    echo "Full response:"
    echo "$CREATE_RESPONSE" | head -c 500
    exit 1
fi
