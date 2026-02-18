#!/bin/bash

# Mikrus Toolbox - Cloudflare DNS Add
# Dodaje rekord DNS do Cloudflare (A lub AAAA).
# Wymaga wcześniejszej konfiguracji: ./local/setup-cloudflare.sh
# Author: Paweł (Lazy Engineer)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

CONFIG_FILE="$HOME/.config/cloudflare/config"

# IP Cytrusa (Mikrus reverse proxy)
CYTRUS_IP="135.181.95.85"

# Argumenty
FULL_DOMAIN="$1"
SSH_ALIAS="${2:-mikrus}"
MODE="${3:-cloudflare}"  # "cloudflare" (IPv6+proxy) lub "cytrus" (IPv4, no proxy)

# Użycie
if [ -z "$FULL_DOMAIN" ]; then
    echo "Użycie: $0 <subdomena.domena.pl> [ssh_alias] [mode]"
    echo ""
    echo "Tryby:"
    echo "  cloudflare  - AAAA record (IPv6 serwera) + proxy ON (domyślny)"
    echo "  cytrus      - A record → $CYTRUS_IP + proxy OFF"
    echo ""
    echo "Przykłady:"
    echo "  $0 app.mojafirma.pl                    # Cloudflare + Caddy"
    echo "  $0 app.mojafirma.pl mikrus              # z innego serwera"
    echo "  $0 app.mojafirma.pl mikrus cytrus       # dla Cytrus API"
    echo ""
    echo "Wymaga wcześniejszej konfiguracji: ./local/setup-cloudflare.sh"
    exit 1
fi

# Ustal typ rekordu i IP
if [ "$MODE" = "cytrus" ]; then
    RECORD_TYPE="A"
    IP_ADDRESS="$CYTRUS_IP"
    PROXY="false"
    echo "🍊 Tryb Cytrus"
    echo "   Rekord: A → $IP_ADDRESS"
    echo "   Proxy: OFF (Cytrus obsługuje SSL)"
else
    RECORD_TYPE="AAAA"
    PROXY="true"
    echo "☁️  Tryb Cloudflare"
    echo "🔍 Pobieram IPv6 serwera '$SSH_ALIAS'..."
    IP_ADDRESS=$(server_exec "ip -6 addr show scope global | grep -oP '(?<=inet6 )[0-9a-f:]+' | head -1" 2>/dev/null)

    if [ -z "$IP_ADDRESS" ]; then
        echo "❌ Nie udało się pobrać IPv6 z serwera '$SSH_ALIAS'"
        exit 1
    fi
    echo "   Rekord: AAAA → $IP_ADDRESS"
    echo "   Proxy: ON (żółta chmurka)"
fi
echo ""

# Sprawdź konfigurację
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Brak konfiguracji Cloudflare!"
    echo "   Uruchom najpierw: ./local/setup-cloudflare.sh"
    exit 1
fi

# Wczytaj token
API_TOKEN=$(grep "^API_TOKEN=" "$CONFIG_FILE" | cut -d= -f2)

if [ -z "$API_TOKEN" ]; then
    echo "❌ Brak API_TOKEN w konfiguracji!"
    exit 1
fi

# Wyciągnij domenę główną z pełnej subdomeny
ROOT_DOMAIN=$(echo "$FULL_DOMAIN" | rev | cut -d. -f1-2 | rev)
SUBDOMAIN=$(echo "$FULL_DOMAIN" | sed "s/\.$ROOT_DOMAIN$//")

if [ "$SUBDOMAIN" = "$ROOT_DOMAIN" ]; then
    SUBDOMAIN="@"
fi

echo "📍 Domena: $ROOT_DOMAIN"
echo "📍 Subdomena: $SUBDOMAIN"
echo ""

# Znajdź Zone ID
ZONE_ID=$(grep "^${ROOT_DOMAIN}=" "$CONFIG_FILE" | cut -d= -f2)

if [ -z "$ZONE_ID" ]; then
    echo "❌ Nie znaleziono Zone ID dla domeny: $ROOT_DOMAIN"
    echo "   Dostępne domeny w konfiguracji:"
    grep -v "^#" "$CONFIG_FILE" | grep -v "API_TOKEN" | grep "=" || echo "   (brak)"
    echo ""
    echo "   Uruchom ponownie: ./local/setup-cloudflare.sh"
    exit 1
fi

echo "🔑 Zone ID: $ZONE_ID"
echo ""

# Sprawdź czy rekord już istnieje
echo "Sprawdzam istniejące rekordy..."
EXISTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$RECORD_TYPE&name=$FULL_DOMAIN" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json")

EXISTING_ID=$(echo "$EXISTING" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//g' | sed 's/"//g')

if [ -n "$EXISTING_ID" ]; then
    echo "⚠️  Rekord $RECORD_TYPE dla $FULL_DOMAIN już istnieje!"
    EXISTING_IP=$(echo "$EXISTING" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//g' | sed 's/"//g')
    echo "   Obecny IP: $EXISTING_IP"

    # Jeśli IP jest takie samo - nic nie rób, sukces
    if [ "$EXISTING_IP" = "$IP_ADDRESS" ]; then
        echo "✅ DNS już skonfigurowany poprawnie!"
        exit 0
    fi

    # Pytaj tylko gdy terminal jest interaktywny
    if [ -t 0 ]; then
        echo ""
        read -p "Zaktualizować na $IP_ADDRESS? (t/N) " -n 1 -r
        echo ""
    else
        echo "   Tryb nieinteraktywny - pomijam aktualizację"
        exit 0
    fi

    if [[ $REPLY =~ ^[TtYy]$ ]]; then
        UPDATE_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$EXISTING_ID" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$FULL_DOMAIN\",\"content\":\"$IP_ADDRESS\",\"ttl\":3600,\"proxied\":$PROXY}")

        if echo "$UPDATE_RESPONSE" | grep -q '"success":true'; then
            echo "✅ Rekord zaktualizowany!"
        else
            echo "❌ Błąd aktualizacji!"
            echo "$UPDATE_RESPONSE"
            exit 1
        fi
    else
        echo "Anulowano."
        exit 0
    fi
else
    echo "Tworzę rekord $RECORD_TYPE..."
    CREATE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$FULL_DOMAIN\",\"content\":\"$IP_ADDRESS\",\"ttl\":3600,\"proxied\":$PROXY}")

    if echo "$CREATE_RESPONSE" | grep -q '"success":true'; then
        echo "✅ Rekord utworzony!"
    else
        echo "❌ Błąd tworzenia rekordu!"
        echo "$CREATE_RESPONSE"
        exit 1
    fi
fi

echo ""
echo "🎉 DNS skonfigurowany: $FULL_DOMAIN → $IP_ADDRESS ($RECORD_TYPE)"

if [ "$MODE" = "cytrus" ]; then
    echo ""
    echo "🍊 Następny krok - dodaj domenę do Cytrusa:"
    echo "   ./local/cytrus-domain.sh $FULL_DOMAIN PORT $SSH_ALIAS"
else
    echo "☁️  Proxy Cloudflare: WŁĄCZONY"
    echo ""
    echo "🚀 Następny krok - wystaw przez Caddy:"
    echo "   ssh $SSH_ALIAS 'mikrus-expose $FULL_DOMAIN PORT'"
fi

echo ""
echo "⏳ Propagacja DNS może zająć do 5 minut."
echo ""
