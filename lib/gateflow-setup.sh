#!/bin/bash

# StackPilot - GateFlow Setup Library
# Functions for GateFlow configuration (Supabase, Turnstile, etc.)
# Author: Paweł (Lazy Engineer)

# Colors (if not loaded)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
NC="${NC:-\033[0m}"

# Configuration paths
SUPABASE_CONFIG_DIR="${SUPABASE_CONFIG_DIR:-$HOME/.config/supabase}"
SUPABASE_TOKEN_FILE="${SUPABASE_TOKEN_FILE:-$HOME/.config/supabase/access_token}"
GATEFLOW_CONFIG_DIR="${GATEFLOW_CONFIG_DIR:-$HOME/.config/gateflow}"
GATEFLOW_SUPABASE_CONFIG="${GATEFLOW_SUPABASE_CONFIG:-$HOME/.config/gateflow/supabase.env}"

# =============================================================================
# SUPABASE TOKEN MANAGEMENT
# =============================================================================

# Check if we have a valid Supabase token
# Sets: SUPABASE_TOKEN (if valid)
check_saved_supabase_token() {
    if [ -f "$SUPABASE_TOKEN_FILE" ]; then
        local SAVED_TOKEN=$(cat "$SUPABASE_TOKEN_FILE" 2>/dev/null)
        if [ -n "$SAVED_TOKEN" ]; then
            echo "🔑 Found saved Supabase token..."
            # Check if token is valid
            local TEST_RESPONSE=$(curl -s -H "Authorization: Bearer $SAVED_TOKEN" "https://api.supabase.com/v1/projects" 2>/dev/null)
            if echo "$TEST_RESPONSE" | grep -q '"id"'; then
                echo "   ✅ Token is valid"
                SUPABASE_TOKEN="$SAVED_TOKEN"
                return 0
            else
                echo "   ⚠️  Token has expired or is invalid"
                rm -f "$SUPABASE_TOKEN_FILE"
            fi
        fi
    fi
    return 1
}

# Save Supabase token to file
save_supabase_token() {
    local TOKEN="$1"
    if [ -n "$TOKEN" ]; then
        mkdir -p "$SUPABASE_CONFIG_DIR"
        echo "$TOKEN" > "$SUPABASE_TOKEN_FILE"
        chmod 600 "$SUPABASE_TOKEN_FILE"
        echo "   💾 Token saved to ~/.config/supabase/access_token"
    fi
}

# Interactive Supabase login (CLI flow)
# Sets: SUPABASE_TOKEN
supabase_login_flow() {
    # Generate ECDH keys (P-256)
    local TEMP_DIR=$(mktemp -d)
    openssl ecparam -name prime256v1 -genkey -noout -out "$TEMP_DIR/private.pem" 2>/dev/null
    openssl ec -in "$TEMP_DIR/private.pem" -pubout -out "$TEMP_DIR/public.pem" 2>/dev/null

    # Get public key - 65 bytes (04 + X + Y) in HEX format
    local PUBLIC_KEY_RAW=$(openssl ec -in "$TEMP_DIR/private.pem" -pubout -outform DER 2>/dev/null | dd bs=1 skip=26 2>/dev/null | xxd -p | tr -d '\n')

    # Generate session ID (UUID v4) and token name
    local SESSION_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null)
    local TOKEN_NAME="stackpilot_$(hostname | tr '.' '_')_$(date +%s)"

    # Build login URL
    local LOGIN_URL="https://supabase.com/dashboard/cli/login?session_id=${SESSION_ID}&token_name=${TOKEN_NAME}&public_key=${PUBLIC_KEY_RAW}"

    echo "🔐 Logging in to Supabase"
    echo ""
    echo "   A browser window will open with the Supabase login page."
    echo "   After logging in, you will see an 8-character verification code."
    echo "   Copy it and paste it here."
    echo ""
    read -p "   Press Enter to open browser..." _

    if command -v open &>/dev/null; then
        open "$LOGIN_URL"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$LOGIN_URL"
    else
        echo ""
        echo "   Cannot open browser automatically."
        echo "   Open manually: $LOGIN_URL"
    fi

    echo ""
    read -p "Paste verification code: " DEVICE_CODE

    # Poll endpoint for token
    echo ""
    echo "🔑 Fetching token..."
    local POLL_URL="https://api.supabase.com/platform/cli/login/${SESSION_ID}?device_code=${DEVICE_CODE}"

    local TOKEN_RESPONSE=$(curl -s "$POLL_URL")

    if echo "$TOKEN_RESPONSE" | grep -q '"access_token"'; then
        echo "   ✓ Token received, decrypting..."

        # Token in response - we need to decrypt
        local ENCRYPTED_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
        local SERVER_PUBLIC_KEY=$(echo "$TOKEN_RESPONSE" | grep -o '"public_key":"[^"]*"' | cut -d'"' -f4)
        local NONCE=$(echo "$TOKEN_RESPONSE" | grep -o '"nonce":"[^"]*"' | cut -d'"' -f4)

        # Decryption ECDH + AES-GCM
        if command -v node &>/dev/null; then
            # Save data to temporary files
            echo "$SERVER_PUBLIC_KEY" > "$TEMP_DIR/server_pubkey.hex"
            echo "$NONCE" > "$TEMP_DIR/nonce.hex"
            echo "$ENCRYPTED_TOKEN" > "$TEMP_DIR/encrypted.hex"

            SUPABASE_TOKEN=$(TEMP_DIR="$TEMP_DIR" node << 'NODESCRIPT'
const crypto = require('crypto');
const fs = require('fs');

const tempDir = process.env.TEMP_DIR;
const privateKeyPem = fs.readFileSync(tempDir + '/private.pem', 'utf8');
const serverPubKeyHex = fs.readFileSync(tempDir + '/server_pubkey.hex', 'utf8').trim();
const nonceHex = fs.readFileSync(tempDir + '/nonce.hex', 'utf8').trim();
const encryptedHex = fs.readFileSync(tempDir + '/encrypted.hex', 'utf8').trim();

// Decode hex
const serverPubKey = Buffer.from(serverPubKeyHex, 'hex');
const nonce = Buffer.from(nonceHex, 'hex');
const encrypted = Buffer.from(encryptedHex, 'hex');

// Extract raw private key from PEM (last 32 bytes from SEC1/PKCS8)
const privKeyObj = crypto.createPrivateKey(privateKeyPem);
const privKeyDer = privKeyObj.export({type: 'sec1', format: 'der'});
// SEC1 format: 30 len 02 01 01 04 20 [32 bytes private key] ...
const privKeyRaw = privKeyDer.slice(7, 39);

// ECDH with createECDH - accepts raw bytes
const ecdh = crypto.createECDH('prime256v1');
ecdh.setPrivateKey(privKeyRaw);
const sharedSecret = ecdh.computeSecret(serverPubKey);

// AES key = shared secret (32 bytes)
const key = sharedSecret;

// Decrypt AES-GCM
const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
const tag = encrypted.slice(-16);
const ciphertext = encrypted.slice(0, -16);
decipher.setAuthTag(tag);
const decrypted = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
console.log(decrypted.toString('utf8'));
NODESCRIPT
            ) || true
        else
            echo "   Node.js not found - cannot decrypt"
        fi

        if [ -z "$SUPABASE_TOKEN" ] || echo "$SUPABASE_TOKEN" | grep -qiE "error|node:|Error"; then
            supabase_manual_token_flow
        else
            echo "   ✅ Token decrypted!"
        fi
    elif echo "$TOKEN_RESPONSE" | grep -q "Cloudflare"; then
        echo "⚠️  Cloudflare is blocking the request. Generate token manually."
        supabase_manual_token_flow
    else
        echo "❌ Error: $TOKEN_RESPONSE"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    rm -rf "$TEMP_DIR"

    # Save token
    if [ -n "$SUPABASE_TOKEN" ]; then
        save_supabase_token "$SUPABASE_TOKEN"
    fi

    return 0
}

# Manual token retrieval (fallback)
supabase_manual_token_flow() {
    echo ""
    echo "⚠️  Could not decrypt token automatically."
    echo "   But the token was created in Supabase! We'll retrieve it manually."
    echo ""
    echo "   Step by step:"
    echo "   1. A page with Supabase tokens will open shortly"
    echo "   2. Click 'Generate new token'"
    echo "   3. Give it a name (e.g. stackpilot) and click 'Generate token'"
    echo "   4. Copy the generated token (sbp_...) and paste it here"
    echo ""
    echo "   NOTE: Existing tokens cannot be copied - you need to generate a new one!"
    echo ""
    read -p "   Press Enter to open the tokens page..." _
    if command -v open &>/dev/null; then
        open "https://supabase.com/dashboard/account/tokens"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "https://supabase.com/dashboard/account/tokens"
    else
        echo "   Open: https://supabase.com/dashboard/account/tokens"
    fi
    echo ""
    read -p "Paste token (sbp_...): " SUPABASE_TOKEN
}

# =============================================================================
# SUPABASE PROJECT SELECTION
# =============================================================================

# Fetch project list and let user choose
# Requires: SUPABASE_TOKEN
# Sets: PROJECT_REF, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY
select_supabase_project() {
    echo ""
    echo "📋 Fetching project list..."
    local PROJECTS=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" "https://api.supabase.com/v1/projects")

    if ! echo "$PROJECTS" | grep -q '"id"'; then
        echo "❌ Failed to fetch projects: $PROJECTS"
        return 1
    fi

    echo ""
    echo "Your Supabase projects:"
    echo ""

    # Parse projects into array
    PROJECT_IDS=()
    PROJECT_NAMES=()
    local i=1

    # Use jq if available, otherwise grep/sed
    if command -v jq &>/dev/null; then
        while IFS=$'\t' read -r proj_id proj_name; do
            PROJECT_IDS+=("$proj_id")
            PROJECT_NAMES+=("$proj_name")
            echo "   $i) $proj_name ($proj_id)"
            ((i++))
        done < <(echo "$PROJECTS" | jq -r '.[] | "\(.id)\t\(.name)"')
    else
        # Fallback without jq
        while read -r proj_id; do
            local proj_name=$(echo "$PROJECTS" | grep -o "\"id\":\"$proj_id\"[^}]*\"name\":\"[^\"]*\"" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
            if [ -z "$proj_name" ]; then
                proj_name=$(echo "$PROJECTS" | grep -o "\"name\":\"[^\"]*\"[^}]*\"id\":\"$proj_id\"" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
            fi
            PROJECT_IDS+=("$proj_id")
            PROJECT_NAMES+=("$proj_name")
            echo "   $i) $proj_name ($proj_id)"
            ((i++))
        done < <(echo "$PROJECTS" | grep -oE '"id":"[^"]+"' | cut -d'"' -f4)
    fi

    echo ""
    read -p "Choose project number [1-$((i-1))]: " PROJECT_NUM

    # Validate choice
    if [[ "$PROJECT_NUM" =~ ^[0-9]+$ ]] && [ "$PROJECT_NUM" -ge 1 ] && [ "$PROJECT_NUM" -lt "$i" ]; then
        PROJECT_REF="${PROJECT_IDS[$((PROJECT_NUM-1))]}"
        echo "   Selected project: ${PROJECT_NAMES[$((PROJECT_NUM-1))]}"
    else
        echo "❌ Invalid choice"
        return 1
    fi

    echo ""
    echo "🔑 Fetching API keys..."
    # IMPORTANT: ?reveal=true returns full keys (without it new secret keys are masked!)
    local API_KEYS=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys?reveal=true")

    SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

    # Parse API keys (new format: publishable/secret, fallback to legacy)
    if command -v jq &>/dev/null; then
        # New keys (publishable/secret)
        SUPABASE_ANON_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.type == "publishable" and .name == "default") | .api_key')
        SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.type == "secret" and .name == "default") | .api_key')
        # Fallback to legacy if new ones don't exist
        [ -z "$SUPABASE_ANON_KEY" ] && SUPABASE_ANON_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.name == "anon") | .api_key')
        [ -z "$SUPABASE_SERVICE_KEY" ] && SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.name == "service_role") | .api_key')
    else
        # New keys (look for sb_publishable_ and sb_secret_)
        SUPABASE_ANON_KEY=$(echo "$API_KEYS" | grep -o '"type":"publishable"[^}]*"api_key":"[^"]*"' | head -1 | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | grep -o '"type":"secret"[^}]*"api_key":"[^"]*"' | head -1 | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        # Fallback to legacy
        [ -z "$SUPABASE_ANON_KEY" ] && SUPABASE_ANON_KEY=$(echo "$API_KEYS" | grep -o '"anon"[^}]*"api_key":"[^"]*"' | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        [ -z "$SUPABASE_SERVICE_KEY" ] && SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | grep -o '"service_role"[^}]*"api_key":"[^"]*"' | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
    fi

    if [ -n "$SUPABASE_ANON_KEY" ] && [ -n "$SUPABASE_SERVICE_KEY" ]; then
        echo "✅ Supabase keys fetched!"

        # Save project configuration to file
        mkdir -p "$GATEFLOW_CONFIG_DIR"
        cat > "$GATEFLOW_SUPABASE_CONFIG" << EOF
# GateFlow Supabase Configuration
# Generated by deploy.sh
SUPABASE_URL=$SUPABASE_URL
PROJECT_REF=$PROJECT_REF
EOF
        chmod 600 "$GATEFLOW_SUPABASE_CONFIG"
        echo "   💾 Configuration saved to ~/.config/gateflow/supabase.env"
        return 0
    else
        echo "❌ Failed to fetch API keys"
        echo ""
        echo "Possible causes:"
        echo "  - Project doesn't have API keys generated yet"
        echo "  - Token doesn't have permissions to read keys"
        echo ""
        echo "Solution: Copy keys manually"
        echo "  1. Open: https://supabase.com/dashboard/project/$PROJECT_REF/settings/api"
        echo "  2. Run: ./local/setup-gateflow-config.sh"
        return 1
    fi
}

# Fetch Supabase keys for a given project ref (non-interactive)
# Requires: SUPABASE_TOKEN, PROJECT_REF (as argument)
# Sets: PROJECT_REF, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY
fetch_supabase_keys_by_ref() {
    local ref="$1"
    if [ -z "$ref" ]; then
        echo "❌ Missing project ref"
        return 1
    fi

    PROJECT_REF="$ref"
    SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

    echo "🔑 Fetching API keys for project $PROJECT_REF..."
    # IMPORTANT: ?reveal=true returns full keys (without it new secret keys are masked!)
    local API_KEYS=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys?reveal=true")

    # Check if project exists
    if echo "$API_KEYS" | grep -q '"error"'; then
        echo "❌ Project not found: $PROJECT_REF"
        return 1
    fi

    # Parse API keys (new format: publishable/secret, fallback to legacy)
    if command -v jq &>/dev/null; then
        # New keys (publishable/secret)
        SUPABASE_ANON_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.type == "publishable" and .name == "default") | .api_key')
        SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.type == "secret" and .name == "default") | .api_key')
        # Fallback to legacy if new ones don't exist
        [ -z "$SUPABASE_ANON_KEY" ] && SUPABASE_ANON_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.name == "anon") | .api_key')
        [ -z "$SUPABASE_SERVICE_KEY" ] && SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.name == "service_role") | .api_key')
    else
        # New keys (look for sb_publishable_ and sb_secret_)
        SUPABASE_ANON_KEY=$(echo "$API_KEYS" | grep -o '"type":"publishable"[^}]*"api_key":"[^"]*"' | head -1 | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | grep -o '"type":"secret"[^}]*"api_key":"[^"]*"' | head -1 | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        # Fallback to legacy
        [ -z "$SUPABASE_ANON_KEY" ] && SUPABASE_ANON_KEY=$(echo "$API_KEYS" | grep -o '"anon"[^}]*"api_key":"[^"]*"' | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        [ -z "$SUPABASE_SERVICE_KEY" ] && SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | grep -o '"service_role"[^}]*"api_key":"[^"]*"' | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
    fi

    if [ -n "$SUPABASE_ANON_KEY" ] && [ -n "$SUPABASE_SERVICE_KEY" ]; then
        echo "✅ Supabase keys fetched!"
        return 0
    else
        echo "❌ Failed to fetch API keys"
        echo ""
        echo "Possible causes:"
        echo "  - Project doesn't have API keys generated yet"
        echo "  - Token doesn't have permissions to read keys"
        echo ""
        echo "Check: https://supabase.com/dashboard/project/$PROJECT_REF/settings/api"
        return 1
    fi
}

# =============================================================================
# SUPABASE CONFIGURATION (all in one place)
# =============================================================================

# Configure all Supabase settings for GateFlow
# Requires: SUPABASE_TOKEN, PROJECT_REF
# Optional: DOMAIN, CLOUDFLARE_TURNSTILE_SECRET_KEY
configure_supabase_settings() {
    local DOMAIN="${1:-}"
    local TURNSTILE_SECRET="${2:-}"
    local SSH_ALIAS="${3:-}"

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "🔧 SUPABASE CONFIGURATION"
    echo "════════════════════════════════════════════════════════════════"

    # Fetch current configuration
    echo ""
    echo "📋 Fetching current configuration..."
    local CURRENT_CONFIG=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" \
        "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth")

    if echo "$CURRENT_CONFIG" | grep -q '"error"'; then
        echo -e "${RED}❌ Failed to fetch configuration${NC}"
        return 1
    fi

    # Get current values
    local CURRENT_SITE_URL=""
    local CURRENT_REDIRECT_URLS=""

    if command -v jq &>/dev/null; then
        CURRENT_SITE_URL=$(echo "$CURRENT_CONFIG" | jq -r '.site_url // empty')
        CURRENT_REDIRECT_URLS=$(echo "$CURRENT_CONFIG" | jq -r '.uri_allow_list // empty')
    else
        CURRENT_SITE_URL=$(echo "$CURRENT_CONFIG" | grep -o '"site_url":"[^"]*"' | cut -d'"' -f4)
        CURRENT_REDIRECT_URLS=$(echo "$CURRENT_CONFIG" | grep -o '"uri_allow_list":"[^"]*"' | cut -d'"' -f4)
    fi

    # Build JSON with configuration
    local CONFIG_UPDATES="{}"
    local CHANGES_MADE=false

    # 1. Site URL (used in email templates as {{ .SiteURL }})
    # ALWAYS update to current domain!
    if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
        local NEW_URL="https://$DOMAIN"

        if [ "$CURRENT_SITE_URL" != "$NEW_URL" ]; then
            echo "   🌐 Setting Site URL: $NEW_URL"
            CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq --arg url "$NEW_URL" '. + {site_url: $url}')
            CHANGES_MADE=true

            # Add old domain to Redirect URLs (so old links still work)
            if [ -n "$CURRENT_SITE_URL" ] && [ "$CURRENT_SITE_URL" != "http://localhost:3000" ]; then
                if [ -z "$CURRENT_REDIRECT_URLS" ]; then
                    local NEW_REDIRECT_URLS="$CURRENT_SITE_URL"
                elif ! echo "$CURRENT_REDIRECT_URLS" | grep -q "$CURRENT_SITE_URL"; then
                    local NEW_REDIRECT_URLS="$CURRENT_REDIRECT_URLS,$CURRENT_SITE_URL"
                fi

                if [ -n "$NEW_REDIRECT_URLS" ]; then
                    echo "   📝 Adding old domain to Redirect URLs: $CURRENT_SITE_URL"
                    CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq --arg urls "$NEW_REDIRECT_URLS" '. + {uri_allow_list: $urls}')
                fi
            fi
        else
            echo "   ✅ Site URL already set: $CURRENT_SITE_URL"
        fi
    fi

    # 2. CAPTCHA (Turnstile)
    if [ -n "$TURNSTILE_SECRET" ]; then
        echo "   🔐 Configuring CAPTCHA (Turnstile)..."
        CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
            --arg secret "$TURNSTILE_SECRET" \
            '. + {security_captcha_enabled: true, security_captcha_provider: "turnstile", security_captcha_secret: $secret}')
        CHANGES_MADE=true
    fi

    # 3. Email templates (if available on server)
    if [ -n "$SSH_ALIAS" ]; then
        local REMOTE_TEMPLATES_DIR="/opt/stacks/gateflow/admin-panel/supabase/templates"
        local TEMPLATES_EXIST=$(ssh "$SSH_ALIAS" "ls '$REMOTE_TEMPLATES_DIR'/*.html 2>/dev/null | head -1" 2>/dev/null)

        if [ -n "$TEMPLATES_EXIST" ]; then
            echo "   📧 Configuring email templates..."

            local TEMP_DIR=$(mktemp -d)
            scp -q "$SSH_ALIAS:$REMOTE_TEMPLATES_DIR/"*.html "$TEMP_DIR/" 2>/dev/null

            # Magic Link
            if [ -f "$TEMP_DIR/magic-link.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/magic-link.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    '. + {mailer_templates_magic_link_content: $content, mailer_subjects_magic_link: "Your login link"}')
                CHANGES_MADE=true
            fi

            # Confirmation
            if [ -f "$TEMP_DIR/confirmation.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/confirmation.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    '. + {mailer_templates_confirmation_content: $content, mailer_subjects_confirmation: "Confirm your email"}')
                CHANGES_MADE=true
            fi

            # Recovery
            if [ -f "$TEMP_DIR/recovery.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/recovery.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    '. + {mailer_templates_recovery_content: $content, mailer_subjects_recovery: "Reset your password"}')
                CHANGES_MADE=true
            fi

            # Email change
            if [ -f "$TEMP_DIR/email-change.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/email-change.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    '. + {mailer_templates_email_change_content: $content, mailer_subjects_email_change: "Confirm email address change"}')
                CHANGES_MADE=true
            fi

            # Invite
            if [ -f "$TEMP_DIR/invite.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/invite.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    '. + {mailer_templates_invite_content: $content, mailer_subjects_invite: "Invitation to GateFlow"}')
                CHANGES_MADE=true
            fi

            rm -rf "$TEMP_DIR"
        fi
    fi

    # Send configuration if there are changes
    if [ "$CHANGES_MADE" = true ]; then
        echo ""
        echo "📤 Saving configuration..."

        local RESPONSE=$(curl -s -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
            -H "Authorization: Bearer $SUPABASE_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$CONFIG_UPDATES")

        if echo "$RESPONSE" | grep -q '"error"'; then
            local ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
            echo -e "${RED}   ❌ Error: $ERROR${NC}"
            return 1
        else
            echo -e "${GREEN}   ✅ Supabase configuration saved!${NC}"
        fi
    else
        echo "   ℹ️  No changes to save"
    fi

    return 0
}

# Update Site URL (for Cytrus after domain assignment)
# Site URL MUST be the current domain (used in {{ .SiteURL }} in emails)
update_supabase_site_url() {
    local NEW_DOMAIN="$1"

    echo ""
    echo "🌐 Updating Site URL in Supabase: https://$NEW_DOMAIN"

    # Variables should already be set by gateflow_collect_config
    # Fallback to config files if for some reason they aren't
    if [ -z "$SUPABASE_TOKEN" ]; then
        [ -f "$SUPABASE_TOKEN_FILE" ] && SUPABASE_TOKEN=$(cat "$SUPABASE_TOKEN_FILE")
    fi
    if [ -z "$PROJECT_REF" ]; then
        [ -f "$GATEFLOW_SUPABASE_CONFIG" ] && source "$GATEFLOW_SUPABASE_CONFIG"
    fi

    # Debug info
    if [ -z "$SUPABASE_TOKEN" ]; then
        echo -e "${RED}   ❌ Missing SUPABASE_TOKEN${NC}"
        return 1
    fi
    if [ -z "$PROJECT_REF" ]; then
        echo -e "${RED}   ❌ Missing PROJECT_REF${NC}"
        return 1
    fi

    echo "   Project: $PROJECT_REF"

    local NEW_URL="https://$NEW_DOMAIN"

    # Fetch current configuration
    local CURRENT_CONFIG=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" \
        "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth")

    local CURRENT_SITE_URL=""
    local CURRENT_REDIRECT_URLS=""
    if command -v jq &>/dev/null; then
        CURRENT_SITE_URL=$(echo "$CURRENT_CONFIG" | jq -r '.site_url // empty')
        CURRENT_REDIRECT_URLS=$(echo "$CURRENT_CONFIG" | jq -r '.uri_allow_list // empty')
    else
        CURRENT_SITE_URL=$(echo "$CURRENT_CONFIG" | grep -o '"site_url":"[^"]*"' | cut -d'"' -f4)
        CURRENT_REDIRECT_URLS=$(echo "$CURRENT_CONFIG" | grep -o '"uri_allow_list":"[^"]*"' | cut -d'"' -f4)
    fi

    # If Site URL is already the same - do nothing
    if [ "$CURRENT_SITE_URL" = "$NEW_URL" ]; then
        echo "   ✅ Site URL already set: $NEW_URL"
        return 0
    fi

    # Build JSON - ALWAYS update Site URL
    local UPDATE_JSON="{\"site_url\":\"$NEW_URL\""

    # Add old domain to Redirect URLs (so old links still work)
    if [ -n "$CURRENT_SITE_URL" ] && [ "$CURRENT_SITE_URL" != "http://localhost:3000" ]; then
        if [ -z "$CURRENT_REDIRECT_URLS" ]; then
            UPDATE_JSON="$UPDATE_JSON,\"uri_allow_list\":\"$CURRENT_SITE_URL\""
            echo "   📝 Adding old domain to Redirect URLs: $CURRENT_SITE_URL"
        elif ! echo "$CURRENT_REDIRECT_URLS" | grep -q "$CURRENT_SITE_URL"; then
            UPDATE_JSON="$UPDATE_JSON,\"uri_allow_list\":\"$CURRENT_REDIRECT_URLS,$CURRENT_SITE_URL\""
            echo "   📝 Adding old domain to Redirect URLs: $CURRENT_SITE_URL"
        fi
    fi

    UPDATE_JSON="$UPDATE_JSON}"

    local RESPONSE=$(curl -s -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
        -H "Authorization: Bearer $SUPABASE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$UPDATE_JSON")

    if echo "$RESPONSE" | grep -q '"error"'; then
        local ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        echo -e "${RED}   ❌ Error updating Site URL: $ERROR${NC}"
        echo "   Response: $RESPONSE"
        return 1
    else
        echo "   ✅ Site URL updated: $NEW_URL"
    fi

    return 0
}

# =============================================================================
# MAIN SETUP FUNCTION
# =============================================================================

# Full GateFlow setup (question gathering)
# Sets all variables needed for installation
# Called in GATHERING PHASE (before "Now sit back and relax")
gateflow_collect_config() {
    local DOMAIN="${1:-}"

    echo "════════════════════════════════════════════════════════════════"
    echo "📋 SUPABASE CONFIGURATION"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # 1. Token
    if ! check_saved_supabase_token; then
        if ! supabase_login_flow; then
            return 1
        fi
    fi

    # 2. Project selection
    if ! select_supabase_project; then
        return 1
    fi

    echo ""
    return 0
}

# Supabase configuration after installation (in EXECUTION PHASE)
# Called after starting the application
gateflow_configure_supabase() {
    local DOMAIN="${1:-}"
    local TURNSTILE_SECRET="${2:-}"
    local SSH_ALIAS="${3:-}"

    configure_supabase_settings "$DOMAIN" "$TURNSTILE_SECRET" "$SSH_ALIAS"
}

# Show Turnstile reminder (for automatic Cytrus domain)
# Called in summary when Turnstile was not configured
gateflow_show_turnstile_reminder() {
    local DOMAIN="${1:-}"
    local SSH_ALIAS="${2:-}"

    if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
        echo ""
        echo -e "${YELLOW}🔒 Configure Turnstile (CAPTCHA) for bot protection:${NC}"
        echo -e "   ${BLUE}./local/setup-turnstile.sh $DOMAIN $SSH_ALIAS${NC}"
        echo ""
    fi
}

# =============================================================================
# STRIPE CONFIGURATION
# =============================================================================

# Collect Stripe configuration (local prompt in PHASE 1.5)
# Sets: STRIPE_PK, STRIPE_SK, STRIPE_WEBHOOK_SECRET, GATEFLOW_STRIPE_CONFIGURED
gateflow_collect_stripe_config() {
    # If we already have keys (passed via env or previous config) - skip
    if [ -n "$STRIPE_PK" ] && [ -n "$STRIPE_SK" ]; then
        GATEFLOW_STRIPE_CONFIGURED=true
        return 0
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "💳 STRIPE CONFIGURATION"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "GateFlow needs Stripe keys to handle payments."
    echo "You can configure them now or later in the GateFlow panel."
    echo ""

    if [ "$YES_MODE" = true ]; then
        echo "⏭️  --yes mode: Stripe will be configured in the panel after installation."
        GATEFLOW_STRIPE_CONFIGURED=false
        return 0
    fi

    read -p "Configure Stripe now? [y/N]: " STRIPE_CHOICE

    if [[ "$STRIPE_CHOICE" =~ ^[TtYy1]$ ]]; then
        echo ""
        echo "   1. Open: https://dashboard.stripe.com/apikeys"
        echo "   2. Copy 'Publishable key' (pk_live_... or pk_test_...)"
        echo "   3. Copy 'Secret key' (sk_live_... or sk_test_...)"
        echo ""
        read -p "STRIPE_PUBLISHABLE_KEY (pk_...): " STRIPE_PK
        read -p "STRIPE_SECRET_KEY (sk_...): " STRIPE_SK
        read -p "STRIPE_WEBHOOK_SECRET (whsec_..., optional - Enter to skip): " STRIPE_WEBHOOK_SECRET
        GATEFLOW_STRIPE_CONFIGURED=true
        echo ""
        echo -e "${GREEN}✅ Stripe keys collected${NC}"
    else
        echo ""
        echo "⏭️  Skipped - you can configure Stripe in the panel after installation."
        GATEFLOW_STRIPE_CONFIGURED=false
    fi

    return 0
}

# Show post-installation reminders for GateFlow
gateflow_show_post_install_reminders() {
    local DOMAIN="${1:-}"
    local SSH_ALIAS="${2:-}"
    local STRIPE_CONFIGURED="${3:-false}"
    local TURNSTILE_CONFIGURED="${4:-false}"

    # First user = admin
    echo ""
    echo "👤 Open https://$DOMAIN - the first user will become admin"

    # Stripe Webhook (always needed for payments)
    echo ""
    echo -e "${YELLOW}💳 Stripe Webhook:${NC}"
    echo "   1. Open: https://dashboard.stripe.com/webhooks"
    echo "   2. Add endpoint: https://$DOMAIN/api/webhooks/stripe"
    echo "   3. Events: checkout.session.completed, payment_intent.succeeded"
    echo "   4. Copy Signing secret (whsec_...) to .env.local"

    # Stripe keys (if not configured)
    if [ "$STRIPE_CONFIGURED" != true ]; then
        echo ""
        echo -e "${YELLOW}💳 Stripe API Keys:${NC} (if not configured)"
        echo -e "   ${BLUE}ssh $SSH_ALIAS nano /opt/stacks/gateflow/admin-panel/.env.local${NC}"
    fi

    # Turnstile
    if [ "$TURNSTILE_CONFIGURED" != true ] && [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
        echo ""
        echo -e "${YELLOW}🔒 Turnstile (CAPTCHA):${NC}"
        echo -e "   ${BLUE}./local/setup-turnstile.sh $DOMAIN $SSH_ALIAS${NC}"
    fi

    # SMTP
    echo ""
    echo -e "${YELLOW}📧 SMTP (email delivery):${NC}"
    echo -e "   ${BLUE}./local/setup-supabase-email.sh${NC}"
    echo ""
}
