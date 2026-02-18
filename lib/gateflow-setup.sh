#!/bin/bash

# StackPilot - GateFlow Setup Library
# Funkcje do konfiguracji GateFlow (Supabase, Turnstile, etc.)
# Author: Paweł (Lazy Engineer)

# Kolory (jeśli nie załadowane)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
NC="${NC:-\033[0m}"

# Ścieżki konfiguracji
SUPABASE_CONFIG_DIR="${SUPABASE_CONFIG_DIR:-$HOME/.config/supabase}"
SUPABASE_TOKEN_FILE="${SUPABASE_TOKEN_FILE:-$HOME/.config/supabase/access_token}"
GATEFLOW_CONFIG_DIR="${GATEFLOW_CONFIG_DIR:-$HOME/.config/gateflow}"
GATEFLOW_SUPABASE_CONFIG="${GATEFLOW_SUPABASE_CONFIG:-$HOME/.config/gateflow/supabase.env}"

# =============================================================================
# SUPABASE TOKEN MANAGEMENT
# =============================================================================

# Sprawdź czy mamy ważny token Supabase
# Ustawia: SUPABASE_TOKEN (jeśli ważny)
check_saved_supabase_token() {
    if [ -f "$SUPABASE_TOKEN_FILE" ]; then
        local SAVED_TOKEN=$(cat "$SUPABASE_TOKEN_FILE" 2>/dev/null)
        if [ -n "$SAVED_TOKEN" ]; then
            echo "🔑 Znaleziono zapisany token Supabase..."
            # Sprawdź czy token jest ważny
            local TEST_RESPONSE=$(curl -s -H "Authorization: Bearer $SAVED_TOKEN" "https://api.supabase.com/v1/projects" 2>/dev/null)
            if echo "$TEST_RESPONSE" | grep -q '"id"'; then
                echo "   ✅ Token jest aktualny"
                SUPABASE_TOKEN="$SAVED_TOKEN"
                return 0
            else
                echo "   ⚠️  Token wygasł lub jest nieprawidłowy"
                rm -f "$SUPABASE_TOKEN_FILE"
            fi
        fi
    fi
    return 1
}

# Zapisz token Supabase do pliku
save_supabase_token() {
    local TOKEN="$1"
    if [ -n "$TOKEN" ]; then
        mkdir -p "$SUPABASE_CONFIG_DIR"
        echo "$TOKEN" > "$SUPABASE_TOKEN_FILE"
        chmod 600 "$SUPABASE_TOKEN_FILE"
        echo "   💾 Token zapisany do ~/.config/supabase/access_token"
    fi
}

# Interaktywne logowanie do Supabase (CLI flow)
# Ustawia: SUPABASE_TOKEN
supabase_login_flow() {
    # Generuj klucze ECDH (P-256)
    local TEMP_DIR=$(mktemp -d)
    openssl ecparam -name prime256v1 -genkey -noout -out "$TEMP_DIR/private.pem" 2>/dev/null
    openssl ec -in "$TEMP_DIR/private.pem" -pubout -out "$TEMP_DIR/public.pem" 2>/dev/null

    # Pobierz publiczny klucz - 65 bajtów (04 + X + Y) w formacie HEX
    local PUBLIC_KEY_RAW=$(openssl ec -in "$TEMP_DIR/private.pem" -pubout -outform DER 2>/dev/null | dd bs=1 skip=26 2>/dev/null | xxd -p | tr -d '\n')

    # Generuj session ID (UUID v4) i token name
    local SESSION_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null)
    local TOKEN_NAME="mikrus_toolbox_$(hostname | tr '.' '_')_$(date +%s)"

    # Buduj URL logowania
    local LOGIN_URL="https://supabase.com/dashboard/cli/login?session_id=${SESSION_ID}&token_name=${TOKEN_NAME}&public_key=${PUBLIC_KEY_RAW}"

    echo "🔐 Logowanie do Supabase"
    echo ""
    echo "   Za chwilę otworzy się przeglądarka ze stroną logowania Supabase."
    echo "   Po zalogowaniu zobaczysz 8-znakowy kod weryfikacyjny."
    echo "   Skopiuj go i wklej tutaj."
    echo ""
    read -p "   Naciśnij Enter aby otworzyć przeglądarkę..." _

    if command -v open &>/dev/null; then
        open "$LOGIN_URL"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$LOGIN_URL"
    else
        echo ""
        echo "   Nie mogę otworzyć przeglądarki automatycznie."
        echo "   Otwórz ręcznie: $LOGIN_URL"
    fi

    echo ""
    read -p "Wklej kod weryfikacyjny: " DEVICE_CODE

    # Polluj endpoint po token
    echo ""
    echo "🔑 Pobieram token..."
    local POLL_URL="https://api.supabase.com/platform/cli/login/${SESSION_ID}?device_code=${DEVICE_CODE}"

    local TOKEN_RESPONSE=$(curl -s "$POLL_URL")

    if echo "$TOKEN_RESPONSE" | grep -q '"access_token"'; then
        echo "   ✓ Token otrzymany, deszyfruję..."

        # Token w odpowiedzi - potrzebujemy odszyfrować
        local ENCRYPTED_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
        local SERVER_PUBLIC_KEY=$(echo "$TOKEN_RESPONSE" | grep -o '"public_key":"[^"]*"' | cut -d'"' -f4)
        local NONCE=$(echo "$TOKEN_RESPONSE" | grep -o '"nonce":"[^"]*"' | cut -d'"' -f4)

        # Deszyfrowanie ECDH + AES-GCM
        if command -v node &>/dev/null; then
            # Zapisz dane do plików tymczasowych
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

// Dekoduj hex
const serverPubKey = Buffer.from(serverPubKeyHex, 'hex');
const nonce = Buffer.from(nonceHex, 'hex');
const encrypted = Buffer.from(encryptedHex, 'hex');

// Wyciągnij raw private key z PEM (ostatnie 32 bajty z SEC1/PKCS8)
const privKeyObj = crypto.createPrivateKey(privateKeyPem);
const privKeyDer = privKeyObj.export({type: 'sec1', format: 'der'});
// SEC1 format: 30 len 02 01 01 04 20 [32 bytes private key] ...
const privKeyRaw = privKeyDer.slice(7, 39);

// ECDH z createECDH - przyjmuje raw bytes
const ecdh = crypto.createECDH('prime256v1');
ecdh.setPrivateKey(privKeyRaw);
const sharedSecret = ecdh.computeSecret(serverPubKey);

// Klucz AES = shared secret (32 bajty)
const key = sharedSecret;

// Deszyfruj AES-GCM
const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
const tag = encrypted.slice(-16);
const ciphertext = encrypted.slice(0, -16);
decipher.setAuthTag(tag);
const decrypted = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
console.log(decrypted.toString('utf8'));
NODESCRIPT
            ) || true
        else
            echo "   Brak Node.js - nie mogę odszyfrować"
        fi

        if [ -z "$SUPABASE_TOKEN" ] || echo "$SUPABASE_TOKEN" | grep -qiE "error|node:|Error"; then
            supabase_manual_token_flow
        else
            echo "   ✅ Token odszyfrowany!"
        fi
    elif echo "$TOKEN_RESPONSE" | grep -q "Cloudflare"; then
        echo "⚠️  Cloudflare blokuje request. Wygeneruj token ręcznie."
        supabase_manual_token_flow
    else
        echo "❌ Błąd: $TOKEN_RESPONSE"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    rm -rf "$TEMP_DIR"

    # Zapisz token
    if [ -n "$SUPABASE_TOKEN" ]; then
        save_supabase_token "$SUPABASE_TOKEN"
    fi

    return 0
}

# Ręczne pobranie tokena (fallback)
supabase_manual_token_flow() {
    echo ""
    echo "⚠️  Nie udało się odszyfrować tokena automatycznie."
    echo "   Ale token został utworzony w Supabase! Pobierzemy go ręcznie."
    echo ""
    echo "   Krok po kroku:"
    echo "   1. Za chwilę otworzy się strona z tokenami Supabase"
    echo "   2. Kliknij 'Generate new token'"
    echo "   3. Nadaj mu nazwę (np. mikrus) i kliknij 'Generate token'"
    echo "   4. Skopiuj wygenerowany token (sbp_...) i wklej tutaj"
    echo ""
    echo "   UWAGA: Istniejących tokenów nie można skopiować - trzeba wygenerować nowy!"
    echo ""
    read -p "   Naciśnij Enter aby otworzyć stronę z tokenami..." _
    if command -v open &>/dev/null; then
        open "https://supabase.com/dashboard/account/tokens"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "https://supabase.com/dashboard/account/tokens"
    else
        echo "   Otwórz: https://supabase.com/dashboard/account/tokens"
    fi
    echo ""
    read -p "Wklej token (sbp_...): " SUPABASE_TOKEN
}

# =============================================================================
# SUPABASE PROJECT SELECTION
# =============================================================================

# Pobierz listę projektów i pozwól wybrać
# Wymaga: SUPABASE_TOKEN
# Ustawia: PROJECT_REF, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY
select_supabase_project() {
    echo ""
    echo "📋 Pobieram listę projektów..."
    local PROJECTS=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" "https://api.supabase.com/v1/projects")

    if ! echo "$PROJECTS" | grep -q '"id"'; then
        echo "❌ Nie udało się pobrać projektów: $PROJECTS"
        return 1
    fi

    echo ""
    echo "Twoje projekty Supabase:"
    echo ""

    # Parsuj projekty do tablicy
    PROJECT_IDS=()
    PROJECT_NAMES=()
    local i=1

    # Użyj jq jeśli dostępne, inaczej grep/sed
    if command -v jq &>/dev/null; then
        while IFS=$'\t' read -r proj_id proj_name; do
            PROJECT_IDS+=("$proj_id")
            PROJECT_NAMES+=("$proj_name")
            echo "   $i) $proj_name ($proj_id)"
            ((i++))
        done < <(echo "$PROJECTS" | jq -r '.[] | "\(.id)\t\(.name)"')
    else
        # Fallback bez jq
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
    read -p "Wybierz numer projektu [1-$((i-1))]: " PROJECT_NUM

    # Walidacja wyboru
    if [[ "$PROJECT_NUM" =~ ^[0-9]+$ ]] && [ "$PROJECT_NUM" -ge 1 ] && [ "$PROJECT_NUM" -lt "$i" ]; then
        PROJECT_REF="${PROJECT_IDS[$((PROJECT_NUM-1))]}"
        echo "   Wybrany projekt: ${PROJECT_NAMES[$((PROJECT_NUM-1))]}"
    else
        echo "❌ Nieprawidłowy wybór"
        return 1
    fi

    echo ""
    echo "🔑 Pobieram klucze API..."
    # WAŻNE: ?reveal=true zwraca pełne klucze (bez tego nowe secret keys są zamaskowane!)
    local API_KEYS=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys?reveal=true")

    SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

    # Parsuj klucze API (nowy format: publishable/secret, fallback do legacy)
    if command -v jq &>/dev/null; then
        # Nowe klucze (publishable/secret)
        SUPABASE_ANON_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.type == "publishable" and .name == "default") | .api_key')
        SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.type == "secret" and .name == "default") | .api_key')
        # Fallback do legacy jeśli nowe nie istnieją
        [ -z "$SUPABASE_ANON_KEY" ] && SUPABASE_ANON_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.name == "anon") | .api_key')
        [ -z "$SUPABASE_SERVICE_KEY" ] && SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.name == "service_role") | .api_key')
    else
        # Nowe klucze (szukamy sb_publishable_ i sb_secret_)
        SUPABASE_ANON_KEY=$(echo "$API_KEYS" | grep -o '"type":"publishable"[^}]*"api_key":"[^"]*"' | head -1 | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | grep -o '"type":"secret"[^}]*"api_key":"[^"]*"' | head -1 | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        # Fallback do legacy
        [ -z "$SUPABASE_ANON_KEY" ] && SUPABASE_ANON_KEY=$(echo "$API_KEYS" | grep -o '"anon"[^}]*"api_key":"[^"]*"' | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        [ -z "$SUPABASE_SERVICE_KEY" ] && SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | grep -o '"service_role"[^}]*"api_key":"[^"]*"' | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
    fi

    if [ -n "$SUPABASE_ANON_KEY" ] && [ -n "$SUPABASE_SERVICE_KEY" ]; then
        echo "✅ Klucze Supabase pobrane!"

        # Zapisz konfigurację projektu do pliku
        mkdir -p "$GATEFLOW_CONFIG_DIR"
        cat > "$GATEFLOW_SUPABASE_CONFIG" << EOF
# GateFlow Supabase Configuration
# Wygenerowane przez deploy.sh
SUPABASE_URL=$SUPABASE_URL
PROJECT_REF=$PROJECT_REF
EOF
        chmod 600 "$GATEFLOW_SUPABASE_CONFIG"
        echo "   💾 Konfiguracja zapisana do ~/.config/gateflow/supabase.env"
        return 0
    else
        echo "❌ Nie udało się pobrać kluczy API"
        echo ""
        echo "Możliwe przyczyny:"
        echo "  • Projekt nie ma jeszcze wygenerowanych kluczy API"
        echo "  • Token nie ma uprawnień do odczytu kluczy"
        echo ""
        echo "Rozwiązanie: Skopiuj klucze ręcznie"
        echo "  1. Otwórz: https://supabase.com/dashboard/project/$PROJECT_REF/settings/api"
        echo "  2. Uruchom: ./local/setup-gateflow-config.sh"
        return 1
    fi
}

# Pobierz klucze Supabase dla podanego project ref (bez interakcji)
# Wymaga: SUPABASE_TOKEN, PROJECT_REF (jako argument)
# Ustawia: PROJECT_REF, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY
fetch_supabase_keys_by_ref() {
    local ref="$1"
    if [ -z "$ref" ]; then
        echo "❌ Brak project ref"
        return 1
    fi

    PROJECT_REF="$ref"
    SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

    echo "🔑 Pobieram klucze API dla projektu $PROJECT_REF..."
    # WAŻNE: ?reveal=true zwraca pełne klucze (bez tego nowe secret keys są zamaskowane!)
    local API_KEYS=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys?reveal=true")

    # Sprawdź czy projekt istnieje
    if echo "$API_KEYS" | grep -q '"error"'; then
        echo "❌ Nie znaleziono projektu: $PROJECT_REF"
        return 1
    fi

    # Parsuj klucze API (nowy format: publishable/secret, fallback do legacy)
    if command -v jq &>/dev/null; then
        # Nowe klucze (publishable/secret)
        SUPABASE_ANON_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.type == "publishable" and .name == "default") | .api_key')
        SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.type == "secret" and .name == "default") | .api_key')
        # Fallback do legacy jeśli nowe nie istnieją
        [ -z "$SUPABASE_ANON_KEY" ] && SUPABASE_ANON_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.name == "anon") | .api_key')
        [ -z "$SUPABASE_SERVICE_KEY" ] && SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | jq -r '.[] | select(.name == "service_role") | .api_key')
    else
        # Nowe klucze (szukamy sb_publishable_ i sb_secret_)
        SUPABASE_ANON_KEY=$(echo "$API_KEYS" | grep -o '"type":"publishable"[^}]*"api_key":"[^"]*"' | head -1 | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | grep -o '"type":"secret"[^}]*"api_key":"[^"]*"' | head -1 | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        # Fallback do legacy
        [ -z "$SUPABASE_ANON_KEY" ] && SUPABASE_ANON_KEY=$(echo "$API_KEYS" | grep -o '"anon"[^}]*"api_key":"[^"]*"' | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
        [ -z "$SUPABASE_SERVICE_KEY" ] && SUPABASE_SERVICE_KEY=$(echo "$API_KEYS" | grep -o '"service_role"[^}]*"api_key":"[^"]*"' | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
    fi

    if [ -n "$SUPABASE_ANON_KEY" ] && [ -n "$SUPABASE_SERVICE_KEY" ]; then
        echo "✅ Klucze Supabase pobrane!"
        return 0
    else
        echo "❌ Nie udało się pobrać kluczy API"
        echo ""
        echo "Możliwe przyczyny:"
        echo "  • Projekt nie ma jeszcze wygenerowanych kluczy API"
        echo "  • Token nie ma uprawnień do odczytu kluczy"
        echo ""
        echo "Sprawdź: https://supabase.com/dashboard/project/$PROJECT_REF/settings/api"
        return 1
    fi
}

# =============================================================================
# SUPABASE CONFIGURATION (wszystko w jednym miejscu)
# =============================================================================

# Skonfiguruj wszystkie ustawienia Supabase dla GateFlow
# Wymaga: SUPABASE_TOKEN, PROJECT_REF
# Opcjonalne: DOMAIN, CLOUDFLARE_TURNSTILE_SECRET_KEY
configure_supabase_settings() {
    local DOMAIN="${1:-}"
    local TURNSTILE_SECRET="${2:-}"
    local SSH_ALIAS="${3:-}"

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "🔧 KONFIGURACJA SUPABASE"
    echo "════════════════════════════════════════════════════════════════"

    # Pobierz obecną konfigurację
    echo ""
    echo "📋 Pobieram obecną konfigurację..."
    local CURRENT_CONFIG=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" \
        "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth")

    if echo "$CURRENT_CONFIG" | grep -q '"error"'; then
        echo -e "${RED}❌ Nie udało się pobrać konfiguracji${NC}"
        return 1
    fi

    # Pobierz obecne wartości
    local CURRENT_SITE_URL=""
    local CURRENT_REDIRECT_URLS=""

    if command -v jq &>/dev/null; then
        CURRENT_SITE_URL=$(echo "$CURRENT_CONFIG" | jq -r '.site_url // empty')
        CURRENT_REDIRECT_URLS=$(echo "$CURRENT_CONFIG" | jq -r '.uri_allow_list // empty')
    else
        CURRENT_SITE_URL=$(echo "$CURRENT_CONFIG" | grep -o '"site_url":"[^"]*"' | cut -d'"' -f4)
        CURRENT_REDIRECT_URLS=$(echo "$CURRENT_CONFIG" | grep -o '"uri_allow_list":"[^"]*"' | cut -d'"' -f4)
    fi

    # Buduj JSON z konfiguracją
    local CONFIG_UPDATES="{}"
    local CHANGES_MADE=false

    # 1. Site URL (używany w szablonach email jako {{ .SiteURL }})
    # ZAWSZE aktualizuj na aktualną domenę!
    if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
        local NEW_URL="https://$DOMAIN"

        if [ "$CURRENT_SITE_URL" != "$NEW_URL" ]; then
            echo "   🌐 Ustawiam Site URL: $NEW_URL"
            CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq --arg url "$NEW_URL" '. + {site_url: $url}')
            CHANGES_MADE=true

            # Dodaj starą domenę do Redirect URLs (żeby stare linki działały)
            if [ -n "$CURRENT_SITE_URL" ] && [ "$CURRENT_SITE_URL" != "http://localhost:3000" ]; then
                if [ -z "$CURRENT_REDIRECT_URLS" ]; then
                    local NEW_REDIRECT_URLS="$CURRENT_SITE_URL"
                elif ! echo "$CURRENT_REDIRECT_URLS" | grep -q "$CURRENT_SITE_URL"; then
                    local NEW_REDIRECT_URLS="$CURRENT_REDIRECT_URLS,$CURRENT_SITE_URL"
                fi

                if [ -n "$NEW_REDIRECT_URLS" ]; then
                    echo "   📝 Dodaję starą domenę do Redirect URLs: $CURRENT_SITE_URL"
                    CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq --arg urls "$NEW_REDIRECT_URLS" '. + {uri_allow_list: $urls}')
                fi
            fi
        else
            echo "   ✅ Site URL już ustawiony: $CURRENT_SITE_URL"
        fi
    fi

    # 2. CAPTCHA (Turnstile)
    if [ -n "$TURNSTILE_SECRET" ]; then
        echo "   🔐 Konfiguruję CAPTCHA (Turnstile)..."
        CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
            --arg secret "$TURNSTILE_SECRET" \
            '. + {security_captcha_enabled: true, security_captcha_provider: "turnstile", security_captcha_secret: $secret}')
        CHANGES_MADE=true
    fi

    # 3. Email templates (jeśli dostępne na serwerze)
    if [ -n "$SSH_ALIAS" ]; then
        local REMOTE_TEMPLATES_DIR="/opt/stacks/gateflow/admin-panel/supabase/templates"
        local TEMPLATES_EXIST=$(ssh "$SSH_ALIAS" "ls '$REMOTE_TEMPLATES_DIR'/*.html 2>/dev/null | head -1" 2>/dev/null)

        if [ -n "$TEMPLATES_EXIST" ]; then
            echo "   📧 Konfiguruję szablony email..."

            local TEMP_DIR=$(mktemp -d)
            scp -q "$SSH_ALIAS:$REMOTE_TEMPLATES_DIR/"*.html "$TEMP_DIR/" 2>/dev/null

            # Magic Link
            if [ -f "$TEMP_DIR/magic-link.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/magic-link.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    '. + {mailer_templates_magic_link_content: $content, mailer_subjects_magic_link: "Twój link do logowania"}')
                CHANGES_MADE=true
            fi

            # Confirmation
            if [ -f "$TEMP_DIR/confirmation.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/confirmation.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    '. + {mailer_templates_confirmation_content: $content, mailer_subjects_confirmation: "Potwierdź swój email"}')
                CHANGES_MADE=true
            fi

            # Recovery
            if [ -f "$TEMP_DIR/recovery.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/recovery.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    '. + {mailer_templates_recovery_content: $content, mailer_subjects_recovery: "Zresetuj hasło"}')
                CHANGES_MADE=true
            fi

            # Email change
            if [ -f "$TEMP_DIR/email-change.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/email-change.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    '. + {mailer_templates_email_change_content: $content, mailer_subjects_email_change: "Potwierdź zmianę adresu email"}')
                CHANGES_MADE=true
            fi

            # Invite
            if [ -f "$TEMP_DIR/invite.html" ]; then
                local TEMPLATE_CONTENT=$(cat "$TEMP_DIR/invite.html")
                CONFIG_UPDATES=$(echo "$CONFIG_UPDATES" | jq \
                    --arg content "$TEMPLATE_CONTENT" \
                    '. + {mailer_templates_invite_content: $content, mailer_subjects_invite: "Zaproszenie do GateFlow"}')
                CHANGES_MADE=true
            fi

            rm -rf "$TEMP_DIR"
        fi
    fi

    # Wyślij konfigurację jeśli są zmiany
    if [ "$CHANGES_MADE" = true ]; then
        echo ""
        echo "📤 Zapisuję konfigurację..."

        local RESPONSE=$(curl -s -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
            -H "Authorization: Bearer $SUPABASE_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$CONFIG_UPDATES")

        if echo "$RESPONSE" | grep -q '"error"'; then
            local ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
            echo -e "${RED}   ❌ Błąd: $ERROR${NC}"
            return 1
        else
            echo -e "${GREEN}   ✅ Konfiguracja Supabase zapisana!${NC}"
        fi
    else
        echo "   ℹ️  Brak zmian do zapisania"
    fi

    return 0
}

# Zaktualizuj Site URL (dla Cytrus po przydzieleniu domeny)
# Site URL MUSI być aktualną domeną (używany w {{ .SiteURL }} w emailach)
update_supabase_site_url() {
    local NEW_DOMAIN="$1"

    echo ""
    echo "🌐 Aktualizuję Site URL w Supabase: https://$NEW_DOMAIN"

    # Zmienne powinny być już ustawione przez gateflow_collect_config
    # Fallback do plików config jeśli z jakiegoś powodu nie są
    if [ -z "$SUPABASE_TOKEN" ]; then
        [ -f "$SUPABASE_TOKEN_FILE" ] && SUPABASE_TOKEN=$(cat "$SUPABASE_TOKEN_FILE")
    fi
    if [ -z "$PROJECT_REF" ]; then
        [ -f "$GATEFLOW_SUPABASE_CONFIG" ] && source "$GATEFLOW_SUPABASE_CONFIG"
    fi

    # Debug info
    if [ -z "$SUPABASE_TOKEN" ]; then
        echo -e "${RED}   ❌ Brak SUPABASE_TOKEN${NC}"
        return 1
    fi
    if [ -z "$PROJECT_REF" ]; then
        echo -e "${RED}   ❌ Brak PROJECT_REF${NC}"
        return 1
    fi

    echo "   Projekt: $PROJECT_REF"

    local NEW_URL="https://$NEW_DOMAIN"

    # Pobierz obecną konfigurację
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

    # Jeśli Site URL już jest taki sam - nic nie rób
    if [ "$CURRENT_SITE_URL" = "$NEW_URL" ]; then
        echo "   ✅ Site URL już ustawiony: $NEW_URL"
        return 0
    fi

    # Buduj JSON - ZAWSZE aktualizuj Site URL
    local UPDATE_JSON="{\"site_url\":\"$NEW_URL\""

    # Dodaj starą domenę do Redirect URLs (żeby stare linki działały)
    if [ -n "$CURRENT_SITE_URL" ] && [ "$CURRENT_SITE_URL" != "http://localhost:3000" ]; then
        if [ -z "$CURRENT_REDIRECT_URLS" ]; then
            UPDATE_JSON="$UPDATE_JSON,\"uri_allow_list\":\"$CURRENT_SITE_URL\""
            echo "   📝 Dodaję starą domenę do Redirect URLs: $CURRENT_SITE_URL"
        elif ! echo "$CURRENT_REDIRECT_URLS" | grep -q "$CURRENT_SITE_URL"; then
            UPDATE_JSON="$UPDATE_JSON,\"uri_allow_list\":\"$CURRENT_REDIRECT_URLS,$CURRENT_SITE_URL\""
            echo "   📝 Dodaję starą domenę do Redirect URLs: $CURRENT_SITE_URL"
        fi
    fi

    UPDATE_JSON="$UPDATE_JSON}"

    local RESPONSE=$(curl -s -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
        -H "Authorization: Bearer $SUPABASE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$UPDATE_JSON")

    if echo "$RESPONSE" | grep -q '"error"'; then
        local ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        echo -e "${RED}   ❌ Błąd aktualizacji Site URL: $ERROR${NC}"
        echo "   Response: $RESPONSE"
        return 1
    else
        echo "   ✅ Site URL zaktualizowany: $NEW_URL"
    fi

    return 0
}

# =============================================================================
# GŁÓWNA FUNKCJA SETUP
# =============================================================================

# Pełny setup GateFlow (zbieranie pytań)
# Ustawia wszystkie zmienne potrzebne do instalacji
# Wywoływane w FAZIE ZBIERANIA (przed "Teraz się zrelaksuj")
gateflow_collect_config() {
    local DOMAIN="${1:-}"

    echo "════════════════════════════════════════════════════════════════"
    echo "📋 KONFIGURACJA SUPABASE"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # 1. Token
    if ! check_saved_supabase_token; then
        if ! supabase_login_flow; then
            return 1
        fi
    fi

    # 2. Wybór projektu
    if ! select_supabase_project; then
        return 1
    fi

    echo ""
    return 0
}

# Konfiguracja Supabase po instalacji (w FAZIE WYKONANIA)
# Wywoływane po uruchomieniu aplikacji
gateflow_configure_supabase() {
    local DOMAIN="${1:-}"
    local TURNSTILE_SECRET="${2:-}"
    local SSH_ALIAS="${3:-}"

    configure_supabase_settings "$DOMAIN" "$TURNSTILE_SECRET" "$SSH_ALIAS"
}

# Pokaż przypomnienie o Turnstile (dla automatycznej domeny Cytrus)
# Wywoływane w podsumowaniu gdy Turnstile nie był skonfigurowany
gateflow_show_turnstile_reminder() {
    local DOMAIN="${1:-}"
    local SSH_ALIAS="${2:-}"

    if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
        echo ""
        echo -e "${YELLOW}🔒 Skonfiguruj Turnstile (CAPTCHA) dla ochrony przed botami:${NC}"
        echo -e "   ${BLUE}./local/setup-turnstile.sh $DOMAIN $SSH_ALIAS${NC}"
        echo ""
    fi
}

# =============================================================================
# STRIPE CONFIGURATION
# =============================================================================

# Zbierz konfigurację Stripe (pytanie lokalne w FAZIE 1.5)
# Ustawia: STRIPE_PK, STRIPE_SK, STRIPE_WEBHOOK_SECRET, GATEFLOW_STRIPE_CONFIGURED
gateflow_collect_stripe_config() {
    # Jeśli już mamy klucze (przekazane przez env lub poprzednia konfiguracja) - pomiń
    if [ -n "$STRIPE_PK" ] && [ -n "$STRIPE_SK" ]; then
        GATEFLOW_STRIPE_CONFIGURED=true
        return 0
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "💳 KONFIGURACJA STRIPE"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "GateFlow potrzebuje kluczy Stripe do obsługi płatności."
    echo "Możesz je skonfigurować teraz lub później w panelu GateFlow."
    echo ""

    if [ "$YES_MODE" = true ]; then
        echo "⏭️  Tryb --yes: Stripe zostanie skonfigurowany w panelu po instalacji."
        GATEFLOW_STRIPE_CONFIGURED=false
        return 0
    fi

    read -p "Skonfigurować Stripe teraz? [t/N]: " STRIPE_CHOICE

    if [[ "$STRIPE_CHOICE" =~ ^[TtYy1]$ ]]; then
        echo ""
        echo "   1. Otwórz: https://dashboard.stripe.com/apikeys"
        echo "   2. Skopiuj 'Publishable key' (pk_live_... lub pk_test_...)"
        echo "   3. Skopiuj 'Secret key' (sk_live_... lub sk_test_...)"
        echo ""
        read -p "STRIPE_PUBLISHABLE_KEY (pk_...): " STRIPE_PK
        read -p "STRIPE_SECRET_KEY (sk_...): " STRIPE_SK
        read -p "STRIPE_WEBHOOK_SECRET (whsec_..., opcjonalne - Enter aby pominąć): " STRIPE_WEBHOOK_SECRET
        GATEFLOW_STRIPE_CONFIGURED=true
        echo ""
        echo -e "${GREEN}✅ Klucze Stripe zebrane${NC}"
    else
        echo ""
        echo "⏭️  Pominięto - skonfigurujesz Stripe w panelu po instalacji."
        GATEFLOW_STRIPE_CONFIGURED=false
    fi

    return 0
}

# Pokaż przypomnienia post-instalacyjne dla GateFlow
gateflow_show_post_install_reminders() {
    local DOMAIN="${1:-}"
    local SSH_ALIAS="${2:-}"
    local STRIPE_CONFIGURED="${3:-false}"
    local TURNSTILE_CONFIGURED="${4:-false}"

    # Pierwszy user = admin
    echo ""
    echo "👤 Otwórz https://$DOMAIN - pierwszy user zostanie adminem"

    # Stripe Webhook (zawsze potrzebny dla płatności)
    echo ""
    echo -e "${YELLOW}💳 Stripe Webhook:${NC}"
    echo "   1. Otwórz: https://dashboard.stripe.com/webhooks"
    echo "   2. Add endpoint: https://$DOMAIN/api/webhooks/stripe"
    echo "   3. Events: checkout.session.completed, payment_intent.succeeded"
    echo "   4. Skopiuj Signing secret (whsec_...) do .env.local"

    # Stripe keys (jeśli nie skonfigurowane)
    if [ "$STRIPE_CONFIGURED" != true ]; then
        echo ""
        echo -e "${YELLOW}💳 Stripe API Keys:${NC} (jeśli nie skonfigurowane)"
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
    echo -e "${YELLOW}📧 SMTP (wysyłka emaili):${NC}"
    echo -e "   ${BLUE}./local/setup-supabase-email.sh${NC}"
    echo ""
}
