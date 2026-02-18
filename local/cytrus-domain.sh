#!/bin/bash

# Mikrus Toolbox - Cytrus Domain Setup
# Automatycznie konfiguruje domenę przez API Mikrusa (Cytrus).
# Nie wymaga klikania w panelu!
# Author: Paweł (Lazy Engineer)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

# Argumenty
FULL_DOMAIN="$1"
PORT="$2"
SSH_ALIAS="${3:-mikrus}"

# Użycie
if [ -z "$PORT" ]; then
    echo "Użycie: $0 <domena|-> <port> [ssh_alias]"
    echo ""
    echo "Przykłady:"
    echo "  $0 - 3001                      # automatyczna domena (np. xyz123.byst.re)"
    echo "  $0 mojapp.byst.re 3001         # własna subdomena na byst.re"
    echo "  $0 mojapp.bieda.it 3001        # własna subdomena na bieda.it"
    echo "  $0 mojapp.toadres.pl 3001      # własna subdomena na toadres.pl"
    echo "  $0 - 5001 mikrus                # auto domena na serwerze 'mikrus'"
    echo ""
    echo "💡 Obsługiwane domeny: *.byst.re, *.bieda.it, *.toadres.pl, *.tojest.dev"
    echo "   Dla własnych domen - użyj panelu: https://mikr.us/panel/?a=cytrus"
    exit 1
fi

# Domyślna wartość dla domeny
if [ -z "$FULL_DOMAIN" ]; then
    FULL_DOMAIN="-"
fi

echo ""
echo "🍊 Cytrus Domain Setup"
echo ""
if [ "$FULL_DOMAIN" = "-" ]; then
    echo "   Domena: (automatyczna - byst.re)"
else
    echo "   Domena: $FULL_DOMAIN"
fi
echo "   Port:   $PORT"
echo "   Serwer: $SSH_ALIAS"
echo ""

# Sprawdź czy to obsługiwana domena lub auto
if [ "$FULL_DOMAIN" != "-" ] && [[ "$FULL_DOMAIN" != *".byst.re" ]] && [[ "$FULL_DOMAIN" != *".bieda.it" ]] && [[ "$FULL_DOMAIN" != *".toadres.pl" ]] && [[ "$FULL_DOMAIN" != *".tojest.dev" ]]; then
    echo "⚠️  Własne domeny (spoza byst.re/bieda.it/toadres.pl/tojest.dev) wymagają:"
    echo "   1. Rekordu DNS A → 135.181.95.85 (IP Cytrusa)"
    echo "   2. Konfiguracji w panelu Mikrus"
    echo ""
    echo "💡 Dla automatycznej konfiguracji własnej domeny użyj opcji Cloudflare"
    echo "   (deploy.sh → opcja 2)"
    echo ""
    read -p "Kontynuować mimo to? (t/N): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[TtYy]$ ]]; then
        echo "Przerwano."
        exit 0
    fi
fi

# 1. Pobierz klucz API z serwera
echo "🔑 Pobieram klucz API z serwera..."
API_KEY=$(server_exec 'cat /klucz_api 2>/dev/null' 2>/dev/null)

if [ -z "$API_KEY" ]; then
    echo "❌ Nie znaleziono klucza API na serwerze!"
    echo "   Plik /klucz_api nie istnieje lub jest pusty."
    echo ""
    echo "   Sprawdź czy masz aktywne API w panelu Mikrus:"
    echo "   https://mikr.us/panel/?a=api"
    exit 1
fi

echo "✅ Klucz API pobrany"
echo ""

# 2. Pobierz SRV (pełna nazwa serwera) - potrzebny do API
echo "🔍 Pobieram identyfikator serwera..."
HOSTNAME=$(server_exec 'hostname' 2>/dev/null)
# Format: mikrus107, srv42, etc - używamy pełnej nazwy
SRV="$HOSTNAME"

if [ -z "$SRV" ]; then
    echo "❌ Nie udało się ustalić identyfikatora serwera (SRV)"
    exit 1
fi

echo "✅ Serwer: $SRV"
echo ""

# 3. Wywołaj API Mikrusa
echo "🚀 Konfiguruję domenę przez API Mikrusa..."

RESPONSE=$(curl -s -X POST "https://api.mikr.us/domain" \
    -d "key=$API_KEY" \
    -d "srv=$SRV" \
    -d "domain=$FULL_DOMAIN" \
    -d "port=$PORT")

# 4. Sprawdź odpowiedź
if echo "$RESPONSE" | grep -qi '"status".*gotowe\|"domain"'; then
    # Wyciągnij domenę z odpowiedzi jeśli była automatyczna
    ASSIGNED_DOMAIN=$(echo "$RESPONSE" | sed -n 's/.*"domain"\s*:\s*"\([^"]*\)".*/\1/p')

    if [ "$FULL_DOMAIN" = "-" ] && [ -n "$ASSIGNED_DOMAIN" ]; then
        FULL_DOMAIN="$ASSIGNED_DOMAIN"
    fi

    echo ""
    echo "✅ Domena skonfigurowana przez Cytrus!"
    echo ""
    echo "🎉 Aplikacja dostępna pod:"
    echo "   https://$FULL_DOMAIN"
    echo ""

    if [[ "$FULL_DOMAIN" == *".byst.re" ]] || [[ "$FULL_DOMAIN" == *".bieda.it" ]] || [[ "$FULL_DOMAIN" == *".toadres.pl" ]] || [[ "$FULL_DOMAIN" == *".tojest.dev" ]]; then
        echo "💡 Domena Mikrusa działa od razu - bez konfiguracji DNS!"
    else
        echo "⚠️  Upewnij się że masz rekord DNS:"
        echo "   Typ: A"
        echo "   Nazwa: $(echo $FULL_DOMAIN | cut -d. -f1)"
        echo "   Wartość: 135.181.95.85 (IP Cytrusa)"
    fi
    echo ""

elif echo "$RESPONSE" | grep -qiE "już istnieje|ju.*istnieje|already exists"; then
    echo ""
    echo "⚠️  Domena $FULL_DOMAIN jest już zajęta!"
    echo ""
    echo "💡 Spróbuj innej nazwy, np.:"
    echo "   - ${FULL_DOMAIN%%.*}-2.${FULL_DOMAIN#*.}"
    echo "   - moj-${FULL_DOMAIN}"
    echo ""
    echo "Uruchom ponownie z inną nazwą."
    exit 1

elif echo "$RESPONSE" | grep -qi "error\|błąd\|fail"; then
    echo ""
    echo "❌ Błąd API Mikrusa:"
    echo "   $RESPONSE"
    echo ""
    echo "💡 Sprawdź:"
    echo "   - Czy domena jest poprawna (np. nazwa.byst.re)"
    echo "   - Czy port nie jest już zajęty"
    echo "   - Czy API jest aktywne: https://mikr.us/panel/?a=api"
    exit 1
else
    # Nieznana odpowiedź - pokaż
    echo ""
    echo "📋 Odpowiedź API:"
    echo "   $RESPONSE"
    echo ""
    echo "🤔 Sprawdź w panelu Mikrus czy domena została dodana:"
    echo "   https://mikr.us/panel/?a=hosting_domeny"
fi
