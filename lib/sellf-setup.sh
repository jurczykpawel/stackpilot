#!/bin/bash

# StackPilot - Sellf Setup Library
# Functions for Sellf configuration (Supabase, Turnstile, etc.)
# Author: Paweł (Lazy Engineer)

# Load i18n if not loaded
_SELLF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_SELLF_DIR/i18n.sh"
fi

# Colors (if not loaded)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
NC="${NC:-\033[0m}"

# Configuration paths
SUPABASE_CONFIG_DIR="${SUPABASE_CONFIG_DIR:-$HOME/.config/supabase}"
SUPABASE_TOKEN_FILE="${SUPABASE_TOKEN_FILE:-$HOME/.config/supabase/access_token}"
SELLF_CONFIG_DIR="${SELLF_CONFIG_DIR:-$HOME/.config/stackpilot/sellf}"
SELLF_SUPABASE_CONFIG="${SELLF_SUPABASE_CONFIG:-$HOME/.config/stackpilot/sellf/supabase.env}"

# Migrate from legacy config path if needed
if [ ! -d "$SELLF_CONFIG_DIR" ] && [ -d "$HOME/.config/sellf" ]; then
    mkdir -p "$(dirname "$SELLF_CONFIG_DIR")"
    cp -r "$HOME/.config/sellf" "$SELLF_CONFIG_DIR"
fi

# =============================================================================
# SUPABASE TOKEN MANAGEMENT
# =============================================================================

# Check if we have a valid Supabase token
# Sets: SUPABASE_TOKEN (if valid)
check_saved_supabase_token() {
    if [ -f "$SUPABASE_TOKEN_FILE" ]; then
        local SAVED_TOKEN=$(cat "$SUPABASE_TOKEN_FILE" 2>/dev/null)
        if [ -n "$SAVED_TOKEN" ]; then
            msg "$MSG_SELLF_TOKEN_FOUND"
            # Check if token is valid
            local TEST_RESPONSE=$(curl -s -H "Authorization: Bearer $SAVED_TOKEN" "https://api.supabase.com/v1/projects" 2>/dev/null)
            if echo "$TEST_RESPONSE" | grep -q '"id"'; then
                msg "$MSG_SELLF_TOKEN_VALID"
                SUPABASE_TOKEN="$SAVED_TOKEN"
                return 0
            else
                msg "$MSG_SELLF_TOKEN_EXPIRED"
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
        msg "$MSG_SELLF_TOKEN_SAVED"
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

    msg "$MSG_SELLF_LOGIN_HEADER"
    echo ""
    msg "$MSG_SELLF_LOGIN_BROWSER"
    msg "$MSG_SELLF_LOGIN_CODE"
    msg "$MSG_SELLF_LOGIN_PASTE"
    echo ""
    read -p "$(msg "$MSG_SELLF_LOGIN_OPEN")" _

    if command -v open &>/dev/null; then
        open "$LOGIN_URL"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$LOGIN_URL"
    else
        echo ""
        msg "$MSG_SELLF_LOGIN_NO_BROWSER"
        msg "$MSG_SELLF_LOGIN_MANUAL" "$LOGIN_URL"
    fi

    echo ""
    read -p "$(msg "$MSG_SELLF_LOGIN_ENTER_CODE")" DEVICE_CODE

    # Poll endpoint for token
    echo ""
    msg "$MSG_SELLF_LOGIN_FETCHING"
    local POLL_URL="https://api.supabase.com/platform/cli/login/${SESSION_ID}?device_code=${DEVICE_CODE}"

    local TOKEN_RESPONSE=$(curl -s "$POLL_URL")

    if echo "$TOKEN_RESPONSE" | grep -q '"access_token"'; then
        msg "$MSG_SELLF_LOGIN_RECEIVED"

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
            msg "$MSG_SELLF_LOGIN_NO_NODE"
        fi

        if [ -z "$SUPABASE_TOKEN" ] || echo "$SUPABASE_TOKEN" | grep -qiE "error|node:|Error"; then
            supabase_manual_token_flow
        else
            msg "$MSG_SELLF_LOGIN_DECRYPTED"
        fi
    elif echo "$TOKEN_RESPONSE" | grep -q "Cloudflare"; then
        msg "$MSG_SELLF_LOGIN_CF_BLOCKED"
        supabase_manual_token_flow
    else
        msg "$MSG_SELLF_LOGIN_ERROR" "$TOKEN_RESPONSE"
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
    msg "$MSG_SELLF_MANUAL_HEADER"
    msg "$MSG_SELLF_MANUAL_BUT"
    echo ""
    msg "$MSG_SELLF_MANUAL_STEP1"
    msg "$MSG_SELLF_MANUAL_STEP2"
    msg "$MSG_SELLF_MANUAL_STEP3"
    msg "$MSG_SELLF_MANUAL_STEP4"
    echo ""
    msg "$MSG_SELLF_MANUAL_NOTE"
    echo ""
    read -p "$(msg "$MSG_SELLF_MANUAL_OPEN")" _
    if command -v open &>/dev/null; then
        open "https://supabase.com/dashboard/account/tokens"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "https://supabase.com/dashboard/account/tokens"
    else
        msg "$MSG_SELLF_MANUAL_URL"
    fi
    echo ""
    read -p "$(msg "$MSG_SELLF_MANUAL_PASTE")" SUPABASE_TOKEN
}

# =============================================================================
# SUPABASE PROJECT SELECTION
# =============================================================================

# Fetch project list and let user choose
# Requires: SUPABASE_TOKEN
# Sets: PROJECT_REF, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY
select_supabase_project() {
    echo ""
    msg "$MSG_SELLF_FETCHING_PROJECTS"
    local PROJECTS=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" "https://api.supabase.com/v1/projects")

    if ! echo "$PROJECTS" | grep -q '"id"'; then
        msg "$MSG_SELLF_FETCH_FAILED" "$PROJECTS"
        return 1
    fi

    echo ""
    msg "$MSG_SELLF_YOUR_PROJECTS"
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
    read -p "$(msg "$MSG_SELLF_CHOOSE_PROJECT" "$((i-1))")" PROJECT_NUM

    # Validate choice
    if [[ "$PROJECT_NUM" =~ ^[0-9]+$ ]] && [ "$PROJECT_NUM" -ge 1 ] && [ "$PROJECT_NUM" -lt "$i" ]; then
        PROJECT_REF="${PROJECT_IDS[$((PROJECT_NUM-1))]}"
        msg "$MSG_SELLF_SELECTED_PROJECT" "${PROJECT_NAMES[$((PROJECT_NUM-1))]}"
    else
        msg "$MSG_SELLF_INVALID_CHOICE"
        return 1
    fi

    echo ""
    msg "$MSG_SELLF_FETCHING_KEYS"
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
        msg "$MSG_SELLF_KEYS_OK"

        # Save project configuration to file
        mkdir -p "$SELLF_CONFIG_DIR"
        cat > "$SELLF_SUPABASE_CONFIG" << EOF
# Sellf Supabase Configuration
# Generated by deploy.sh
SUPABASE_URL=$SUPABASE_URL
PROJECT_REF=$PROJECT_REF
EOF
        chmod 600 "$SELLF_SUPABASE_CONFIG"
        msg "$MSG_SELLF_CONFIG_SAVED"
        return 0
    else
        msg "$MSG_SELLF_KEYS_FAIL"
        echo ""
        msg "$MSG_SELLF_KEYS_CAUSE1"
        msg "$MSG_SELLF_KEYS_CAUSE2"
        echo ""
        msg "$MSG_SELLF_KEYS_SOLUTION"
        msg "$MSG_SELLF_KEYS_OPEN" "$PROJECT_REF"
        msg "$MSG_SELLF_KEYS_RUN"
        return 1
    fi
}

# Fetch Supabase keys for a given project ref (non-interactive)
# Requires: SUPABASE_TOKEN, PROJECT_REF (as argument)
# Sets: PROJECT_REF, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY
fetch_supabase_keys_by_ref() {
    local ref="$1"
    if [ -z "$ref" ]; then
        msg "$MSG_SELLF_MISSING_REF"
        return 1
    fi

    PROJECT_REF="$ref"
    SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

    msg "$MSG_SELLF_FETCHING_KEYS_REF" "$PROJECT_REF"
    # IMPORTANT: ?reveal=true returns full keys (without it new secret keys are masked!)
    local API_KEYS=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys?reveal=true")

    # Check if project exists
    if echo "$API_KEYS" | grep -q '"error"'; then
        msg "$MSG_SELLF_PROJECT_NOT_FOUND" "$PROJECT_REF"
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
        msg "$MSG_SELLF_KEYS_OK"
        return 0
    else
        msg "$MSG_SELLF_KEYS_FAIL"
        echo ""
        msg "$MSG_SELLF_KEYS_CAUSE1"
        msg "$MSG_SELLF_KEYS_CAUSE2"
        echo ""
        msg "$MSG_SELLF_KEYS_CHECK" "$PROJECT_REF"
        return 1
    fi
}

# =============================================================================
# SUPABASE CONFIGURATION (all in one place)
# =============================================================================

# Configure all Supabase settings for Sellf
# Requires: SUPABASE_TOKEN, PROJECT_REF
# Optional: DOMAIN, CLOUDFLARE_TURNSTILE_SECRET_KEY
configure_supabase_settings() {
    local DOMAIN="${1:-}"
    local TURNSTILE_SECRET="${2:-}"
    local SSH_ALIAS="${3:-}"

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    msg "$MSG_SELLF_CFG_HEADER"
    echo "════════════════════════════════════════════════════════════════"

    # Fetch current configuration
    echo ""
    msg "$MSG_SELLF_CFG_FETCHING"
    local CURRENT_CONFIG=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" \
        "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth")

    if echo "$CURRENT_CONFIG" | grep -q '"error"'; then
        msg "$MSG_SELLF_CFG_FETCH_FAIL"
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
            msg "$MSG_SELLF_CFG_SITE_URL" "$NEW_URL"
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
                    msg "$MSG_SELLF_CFG_REDIRECT" "$CURRENT_SITE_URL"
                    CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq --arg urls "$NEW_REDIRECT_URLS" '. + {uri_allow_list: $urls}')
                fi
            fi
        else
            msg "$MSG_SELLF_CFG_SITE_OK" "$CURRENT_SITE_URL"
        fi
    fi

    # 2. CAPTCHA (Turnstile)
    if [ -n "$TURNSTILE_SECRET" ]; then
        msg "$MSG_SELLF_CFG_CAPTCHA"
        CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
            --arg secret "$TURNSTILE_SECRET" \
            '. + {security_captcha_enabled: true, security_captcha_provider: "turnstile", security_captcha_secret: $secret}')
        CHANGES_MADE=true
    fi

    # 3. Email templates (if available on server)
    if [ -n "$SSH_ALIAS" ]; then
        local REMOTE_TEMPLATES_DIR="/opt/stacks/sellf/admin-panel/supabase/templates"
        local TEMPLATES_EXIST=$(ssh "$SSH_ALIAS" "ls '$REMOTE_TEMPLATES_DIR'/*.html 2>/dev/null | head -1" 2>/dev/null)

        if [ -n "$TEMPLATES_EXIST" ]; then
            msg "$MSG_SELLF_CFG_TEMPLATES"

            local TEMP_DIR=$(mktemp -d)
            scp -q "$SSH_ALIAS:$REMOTE_TEMPLATES_DIR/"*.html "$TEMP_DIR/" 2>/dev/null

            # Magic Link
            if [ -f "$TEMP_DIR/magic-link.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/magic-link.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    --arg subj "$(msg "$MSG_SELLF_EMAIL_MAGIC_LINK")" \
                    '. + {mailer_templates_magic_link_content: $content, mailer_subjects_magic_link: $subj}')
                CHANGES_MADE=true
            fi

            # Confirmation
            if [ -f "$TEMP_DIR/confirmation.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/confirmation.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    --arg subj "$(msg "$MSG_SELLF_EMAIL_CONFIRMATION")" \
                    '. + {mailer_templates_confirmation_content: $content, mailer_subjects_confirmation: $subj}')
                CHANGES_MADE=true
            fi

            # Recovery
            if [ -f "$TEMP_DIR/recovery.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/recovery.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    --arg subj "$(msg "$MSG_SELLF_EMAIL_RECOVERY")" \
                    '. + {mailer_templates_recovery_content: $content, mailer_subjects_recovery: $subj}')
                CHANGES_MADE=true
            fi

            # Email change
            if [ -f "$TEMP_DIR/email-change.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/email-change.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    --arg subj "$(msg "$MSG_SELLF_EMAIL_CHANGE")" \
                    '. + {mailer_templates_email_change_content: $content, mailer_subjects_email_change: $subj}')
                CHANGES_MADE=true
            fi

            # Invite
            if [ -f "$TEMP_DIR/invite.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/invite.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    --arg subj "$(msg "$MSG_SELLF_EMAIL_INVITE")" \
                    '. + {mailer_templates_invite_content: $content, mailer_subjects_invite: $subj}')
                CHANGES_MADE=true
            fi

            rm -rf "$TEMP_DIR"
        fi
    fi

    # Send configuration if there are changes
    if [ "$CHANGES_MADE" = true ]; then
        echo ""
        msg "$MSG_SELLF_CFG_SAVING"

        local RESPONSE=$(curl -s -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
            -H "Authorization: Bearer $SUPABASE_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$CONFIG_UPDATES")

        if echo "$RESPONSE" | grep -q '"error"'; then
            local ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
            msg "$MSG_SELLF_CFG_ERROR" "$ERROR"
            return 1
        else
            msg "$MSG_SELLF_CFG_SAVED"
        fi
    else
        msg "$MSG_SELLF_CFG_NO_CHANGES"
    fi

    return 0
}

# Update Site URL (after domain assignment)
# Site URL MUST be the current domain (used in {{ .SiteURL }} in emails)
update_supabase_site_url() {
    local NEW_DOMAIN="$1"

    echo ""
    msg "$MSG_SELLF_URL_UPDATING" "$NEW_DOMAIN"

    # Variables should already be set by sellf_collect_config
    # Fallback to config files if for some reason they aren't
    if [ -z "$SUPABASE_TOKEN" ]; then
        [ -f "$SUPABASE_TOKEN_FILE" ] && SUPABASE_TOKEN=$(cat "$SUPABASE_TOKEN_FILE")
    fi
    if [ -z "$PROJECT_REF" ]; then
        [ -f "$SELLF_SUPABASE_CONFIG" ] && source "$SELLF_SUPABASE_CONFIG"
    fi

    # Debug info
    if [ -z "$SUPABASE_TOKEN" ]; then
        msg "$MSG_SELLF_URL_NO_TOKEN"
        return 1
    fi
    if [ -z "$PROJECT_REF" ]; then
        msg "$MSG_SELLF_URL_NO_REF"
        return 1
    fi

    msg "$MSG_SELLF_URL_PROJECT" "$PROJECT_REF"

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
        msg "$MSG_SELLF_URL_ALREADY" "$NEW_URL"
        return 0
    fi

    # Build JSON - ALWAYS update Site URL
    local UPDATE_JSON="{\"site_url\":\"$NEW_URL\""

    # Add old domain to Redirect URLs (so old links still work)
    if [ -n "$CURRENT_SITE_URL" ] && [ "$CURRENT_SITE_URL" != "http://localhost:3000" ]; then
        if [ -z "$CURRENT_REDIRECT_URLS" ]; then
            UPDATE_JSON="$UPDATE_JSON,\"uri_allow_list\":\"$CURRENT_SITE_URL\""
            msg "$MSG_SELLF_URL_REDIRECT" "$CURRENT_SITE_URL"
        elif ! echo "$CURRENT_REDIRECT_URLS" | grep -q "$CURRENT_SITE_URL"; then
            UPDATE_JSON="$UPDATE_JSON,\"uri_allow_list\":\"$CURRENT_REDIRECT_URLS,$CURRENT_SITE_URL\""
            msg "$MSG_SELLF_URL_REDIRECT" "$CURRENT_SITE_URL"
        fi
    fi

    UPDATE_JSON="$UPDATE_JSON}"

    local RESPONSE=$(curl -s -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
        -H "Authorization: Bearer $SUPABASE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$UPDATE_JSON")

    if echo "$RESPONSE" | grep -q '"error"'; then
        local ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        msg "$MSG_SELLF_URL_ERROR" "$ERROR"
        echo "   Response: $RESPONSE"
        return 1
    else
        msg "$MSG_SELLF_URL_UPDATED" "$NEW_URL"
    fi

    return 0
}

# =============================================================================
# MAIN SETUP FUNCTION
# =============================================================================

# Full Sellf setup (question gathering)
# Sets all variables needed for installation
# Called in GATHERING PHASE (before "Now sit back and relax")
sellf_collect_config() {
    local DOMAIN="${1:-}"

    echo "════════════════════════════════════════════════════════════════"
    msg "$MSG_SELLF_COLLECT_HEADER"
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
sellf_configure_supabase() {
    local DOMAIN="${1:-}"
    local TURNSTILE_SECRET="${2:-}"
    local SSH_ALIAS="${3:-}"

    configure_supabase_settings "$DOMAIN" "$TURNSTILE_SECRET" "$SSH_ALIAS"
}

# Show Turnstile reminder (for automatic domain)
# Called in summary when Turnstile was not configured
sellf_show_turnstile_reminder() {
    local DOMAIN="${1:-}"
    local SSH_ALIAS="${2:-}"

    if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
        echo ""
        msg "$MSG_SELLF_TURNSTILE_REM"
        msg "$MSG_SELLF_POST_TURNSTILE_CMD" "$DOMAIN" "$SSH_ALIAS"
        echo ""
    fi
}

# =============================================================================
# STRIPE CONFIGURATION
# =============================================================================

# Collect Stripe configuration (local prompt in PHASE 1.5)
# Sets: STRIPE_PK, STRIPE_SK, STRIPE_WEBHOOK_SECRET, SELLF_STRIPE_CONFIGURED
sellf_collect_stripe_config() {
    # If we already have keys (passed via env or previous config) - skip
    if [ -n "$STRIPE_PK" ] && [ -n "$STRIPE_SK" ]; then
        SELLF_STRIPE_CONFIGURED=true
        return 0
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    msg "$MSG_SELLF_STRIPE_HEADER"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    msg "$MSG_SELLF_STRIPE_INTRO"
    msg "$MSG_SELLF_STRIPE_LATER"
    echo ""

    if [ "$YES_MODE" = true ]; then
        msg "$MSG_SELLF_STRIPE_YES"
        SELLF_STRIPE_CONFIGURED=false
        return 0
    fi

    read -p "$(msg "$MSG_SELLF_STRIPE_PROMPT")" STRIPE_CHOICE

    if [[ "$STRIPE_CHOICE" =~ ^[TtYy1]$ ]]; then
        echo ""
        msg "$MSG_SELLF_STRIPE_STEP1"
        msg "$MSG_SELLF_STRIPE_STEP2"
        msg "$MSG_SELLF_STRIPE_STEP3"
        echo ""
        read -p "STRIPE_PUBLISHABLE_KEY (pk_...): " STRIPE_PK
        read -p "STRIPE_SECRET_KEY (sk_...): " STRIPE_SK
        read -p "STRIPE_WEBHOOK_SECRET (whsec_..., optional - Enter to skip): " STRIPE_WEBHOOK_SECRET
        SELLF_STRIPE_CONFIGURED=true
        echo ""
        msg "$MSG_SELLF_STRIPE_COLLECTED"
    else
        echo ""
        msg "$MSG_SELLF_STRIPE_SKIPPED"
        SELLF_STRIPE_CONFIGURED=false
    fi

    return 0
}

# Show post-installation reminders for Sellf
sellf_show_post_install_reminders() {
    local DOMAIN="${1:-}"
    local SSH_ALIAS="${2:-}"
    local STRIPE_CONFIGURED="${3:-false}"
    local TURNSTILE_CONFIGURED="${4:-false}"

    # First user = admin
    echo ""
    msg "$MSG_SELLF_POST_ADMIN" "$DOMAIN"

    # Stripe Webhook (always needed for payments)
    echo ""
    msg "$MSG_SELLF_POST_WEBHOOK"
    msg "$MSG_SELLF_POST_WH_STEP1"
    msg "$MSG_SELLF_POST_WH_STEP2" "$DOMAIN"
    msg "$MSG_SELLF_POST_WH_STEP3"
    msg "$MSG_SELLF_POST_WH_STEP4"

    # Stripe keys (if not configured)
    if [ "$STRIPE_CONFIGURED" != true ]; then
        echo ""
        msg "$MSG_SELLF_POST_STRIPE"
        msg "$MSG_SELLF_POST_STRIPE_CMD" "$SSH_ALIAS"
    fi

    # Turnstile
    if [ "$TURNSTILE_CONFIGURED" != true ] && [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
        echo ""
        msg "$MSG_SELLF_POST_TURNSTILE"
        msg "$MSG_SELLF_POST_TURNSTILE_CMD" "$DOMAIN" "$SSH_ALIAS"
    fi

    # SMTP
    echo ""
    msg "$MSG_SELLF_POST_SMTP"
    msg "$MSG_SELLF_POST_SMTP_CMD"
    echo ""
}
