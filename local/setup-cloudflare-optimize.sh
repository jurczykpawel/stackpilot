#!/bin/bash

# StackPilot - Cloudflare Optimization
# Ustawia optymalne ustawienia Cloudflare dla domen na Mikrus
# Author: Paweł (Lazy Engineer)
#
# Ustawienia zone (uniwersalne):
#   - SSL: Flexible (Mikrus nie ma własnego certyfikatu)
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
# Reguły są scopowane per hostname i mergowane z istniejącymi.
# Wielokrotne uruchomienie jest bezpieczne (nadpisuje reguły tylko dla danego hosta).

set -e

CONFIG_FILE="$HOME/.config/cloudflare/config"

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parsowanie argumentów
FULL_DOMAIN=""
APP_TYPE=""

for arg in "$@"; do
    case "$arg" in
        --app=*) APP_TYPE="${arg#--app=}" ;;
        -*) echo -e "${RED}❌ Nieznana opcja: $arg${NC}"; exit 1 ;;
        *) FULL_DOMAIN="$arg" ;;
    esac
done

if [ -z "$FULL_DOMAIN" ]; then
    echo "Użycie: $0 <domena> [--app=wordpress|nextjs]"
    echo ""
    echo "Optymalizuje ustawienia Cloudflare dla domeny:"
    echo "  - SSL Flexible (wymagane dla Mikrus)"
    echo "  - Kompresja Brotli"
    echo "  - Always HTTPS, HTTP/2, HTTP/3"
    echo "  - Early Hints"
    echo ""
    echo "Cache Rules (opcjonalne, wymaga --app):"
    echo "  --app=wordpress   Bypass wp-admin/wp-login, cache statyki WP"
    echo "  --app=nextjs      Cache /_next/static/*, bypass /api/*"
    echo ""
    echo "Reguły są scopowane per hostname - bezpieczne dla wielu apek na jednej domenie."
    echo ""
    echo "Przykłady:"
    echo "  $0 app.mojadomena.pl"
    echo "  $0 wp.mojadomena.pl --app=wordpress"
    echo "  $0 next.mojadomena.pl --app=nextjs"
    echo ""
    echo "Wymaga: ./local/setup-cloudflare.sh"
    exit 1
fi

# Walidacja --app
if [ -n "$APP_TYPE" ] && [ "$APP_TYPE" != "wordpress" ] && [ "$APP_TYPE" != "nextjs" ]; then
    echo -e "${RED}❌ Nieznany typ aplikacji: $APP_TYPE${NC}"
    echo "   Dostępne: wordpress, nextjs"
    exit 1
fi

# Sprawdź konfigurację
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Brak konfiguracji Cloudflare${NC}"
    echo "   Uruchom najpierw: ./local/setup-cloudflare.sh"
    exit 1
fi

# Wyciągnij token (nie sourcuj całego pliku - zawiera zone mappings z kropkami)
CF_API_TOKEN=$(grep -E "^(CF_)?API_TOKEN=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2)

if [ -z "$CF_API_TOKEN" ]; then
    echo -e "${RED}❌ Brak tokenu API${NC}"
    exit 1
fi

# Wyciągnij domenę główną (zone)
# app.example.com → example.com
ZONE_NAME=$(echo "$FULL_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')

echo "☁️  Cloudflare Optimization"
echo "   Domena: $FULL_DOMAIN"
echo "   Zone: $ZONE_NAME"
if [ -n "$APP_TYPE" ]; then
    echo "   App: $APP_TYPE"
fi
echo ""

# Pobierz Zone ID
echo "🔍 Szukam Zone ID..."
ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json")

ZONE_ID=$(echo "$ZONE_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$ZONE_ID" ]; then
    echo -e "${RED}❌ Nie znaleziono strefy: $ZONE_NAME${NC}"
    echo "   Upewnij się że domena jest dodana do Cloudflare"
    exit 1
fi

echo "   Zone ID: $ZONE_ID"
echo ""

# Śledzenie błędów uprawnień
PERMISSION_ERRORS=0

# Funkcja do ustawiania opcji zone
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
# USTAWIENIA ZONE
# =============================================================================

echo "⚙️  Ustawienia zone..."

# SSL Flexible - WYMAGANE dla Mikrus (brak certyfikatu na serwerze)
set_zone_setting "ssl" '"flexible"' "SSL Flexible"

# Brotli - lepsza kompresja
set_zone_setting "brotli" '"on"' "Brotli"

# Always HTTPS
set_zone_setting "always_use_https" '"on"' "Always HTTPS"

# Minimum TLS 1.2
set_zone_setting "min_tls_version" '"1.2"' "Min TLS 1.2"

# Early Hints - szybsze ładowanie
set_zone_setting "early_hints" '"on"' "Early Hints"

# HTTP/2
set_zone_setting "http2" '"on"' "HTTP/2"

# HTTP/3 (QUIC)
set_zone_setting "http3" '"on"' "HTTP/3"

echo ""

# =============================================================================
# CACHE RULES (zależne od --app, scopowane per hostname, mergowane)
# =============================================================================

# Generowanie reguł cache per app type (bez hostname - dodawany potem przez jq)
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

# Scopuj reguły per hostname i taguj w opisie
# Input: tablica reguł JSON (stdin), $1 = hostname
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
    echo "📦 Cache Rules ($APP_TYPE → $FULL_DOMAIN)..."

    # Sprawdź jq (wymagane do merge reguł)
    if ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}⚠️  jq nie znalezione - pominięto Cache Rules${NC}"
        echo "   Zainstaluj: brew install jq (macOS) lub apt install jq (Linux)"
        echo ""
    else
        # Pobierz reguły dla wybranej aplikacji i scopuj per hostname
        case "$APP_TYPE" in
            wordpress) NEW_RULES=$(get_wordpress_rules | scope_rules_to_host "$FULL_DOMAIN") ;;
            nextjs)    NEW_RULES=$(get_nextjs_rules | scope_rules_to_host "$FULL_DOMAIN") ;;
        esac

        # Sprawdź czy ruleset już istnieje
        RULESETS_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets?phase=http_request_cache_settings" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json")

        RULESET_ID=$(echo "$RULESETS_RESPONSE" | jq -r '.result[0].id // empty')

        if [ -n "$RULESET_ID" ]; then
            # Pobierz istniejące reguły
            EXISTING_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$RULESET_ID" \
                -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json")

            # Usuń stare reguły dla tego hosta, zachowaj resztę
            KEPT_RULES=$(echo "$EXISTING_RESPONSE" | jq --arg host "$FULL_DOMAIN" '
                [.result.rules[] | select(.description | endswith("[" + $host + "]") | not)]
            ')

            # Merguj: istniejące (bez tego hosta) + nowe
            MERGED=$(jq -n --argjson kept "$KEPT_RULES" --argjson new "$NEW_RULES" '
                {"rules": ($kept + $new)}
            ')

            echo -n "   Aktualizuję cache rules (merge)... "
            RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$RULESET_ID" \
                -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "$MERGED")
        else
            # Utwórz nowy ruleset
            FULL_RULESET=$(jq -n --argjson rules "$NEW_RULES" '{
                "name": "StackPilot Cache Rules",
                "kind": "zone",
                "phase": "http_request_cache_settings",
                "rules": $rules
            }')

            echo -n "   Tworzę cache rules... "
            RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
                -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "$FULL_RULESET")
        fi

        if echo "$RESPONSE" | grep -q '"success":true'; then
            echo -e "${GREEN}✅${NC}"
            CACHE_RULE_OK=true
            case "$APP_TYPE" in
                wordpress)
                    echo "      /wp-admin, /wp-login.php, /wp-json, /wp-cron.php → bypass"
                    echo "      /wp-content/uploads, /wp-includes → cache 1 rok"
                    echo "      /wp-content/themes, /wp-content/plugins → cache 1 tydzień"
                    ;;
                nextjs)
                    echo "      /_next/static/* → cache 1 rok"
                    echo "      /api/* → bypass cache"
                    ;;
            esac
        else
            ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
            if [ -n "$ERROR" ]; then
                echo -e "${YELLOW}⚠️  $ERROR${NC}"
            else
                echo -e "${YELLOW}⚠️  Nie udało się (może brak uprawnień do Cache Rules)${NC}"
            fi
            if echo "$ERROR" | grep -qi "unauthorized\|authentication"; then
                PERMISSION_ERRORS=$((PERMISSION_ERRORS + 1))
            fi
        fi

        echo ""
    fi
else
    echo "ℹ️  Pominięto Cache Rules (użyj --app=wordpress|nextjs aby dodać)"
    echo ""
fi

# Podsumowanie
if [ "$PERMISSION_ERRORS" -gt 0 ]; then
    echo -e "${YELLOW}⚠️  Niektóre ustawienia pominięte (brak uprawnień tokenu)${NC}"
    echo ""
    echo "   Twój token nie ma wymaganych uprawnień. Utwórz nowy token z:"
    echo "   • Zone → Zone Settings → Edit  (SSL, Brotli, HTTPS, TLS)"
    if [ -n "$APP_TYPE" ]; then
        echo "   • Zone → Cache Rules → Edit    (cache dla $APP_TYPE)"
    fi
    echo ""
    echo "   Utwórz token: https://dash.cloudflare.com/profile/api-tokens"
    echo "   Lub ustaw ręcznie w panelu Cloudflare:"
    echo "   → SSL/TLS: Flexible"
    echo "   → Speed → Optimization: włącz Brotli"
    echo ""
else
    echo -e "${GREEN}🎉 Optymalizacja zakończona!${NC}"
    echo ""
    echo "📋 Ustawione:"
    echo "   • SSL: Flexible (wymagane dla Mikrus)"
    echo "   • Kompresja: Brotli"
    echo "   • HTTPS: wymuszony"
    echo "   • TLS: minimum 1.2"
    echo "   • HTTP/2 + HTTP/3"
    echo "   • Early Hints"
    if [ "$CACHE_RULE_OK" = true ]; then
        case "$APP_TYPE" in
            wordpress)
                echo "   • Cache: wp-content/uploads, wp-includes (1 rok)"
                echo "   • Cache: wp-content/themes, plugins (1 tydzień)"
                echo "   • Bypass: wp-admin, wp-login, wp-json, wp-cron"
                ;;
            nextjs)
                echo "   • Cache: /_next/static/* (1 rok)"
                echo "   • No-cache: /api/*"
                ;;
        esac
        echo "   • Scope: $FULL_DOMAIN"
    fi
fi
echo ""
