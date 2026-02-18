#!/bin/bash

# Test pobierania kluczy Supabase przez API
# Sprawdza czy ?reveal=true działa dla nowych projektów

set -e

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}🧪 Test pobierania kluczy Supabase przez API${NC}"
echo ""
echo "Ten test sprawdza czy automatyczne pobieranie kluczy działa z nowymi projektami Supabase."
echo ""

# Załaduj funkcje z lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

source "$LIB_DIR/gateflow-setup.sh"

# Sprawdź czy mamy token
if [ ! -f ~/.config/supabase/access_token ]; then
    echo -e "${RED}❌ Brak tokena Supabase${NC}"
    echo ""
    echo "Musisz najpierw się zalogować:"
    echo "   ./local/setup-gateflow-config.sh"
    echo ""
    exit 1
fi

SUPABASE_TOKEN=$(cat ~/.config/supabase/access_token)

# Pobierz listę projektów
echo "🔍 Pobieram listę Twoich projektów Supabase..."
echo ""

PROJECTS=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" "https://api.supabase.com/v1/projects")

if ! echo "$PROJECTS" | grep -q '"id"'; then
    echo -e "${RED}❌ Nie udało się pobrać projektów${NC}"
    echo "   Sprawdź czy token jest aktualny"
    exit 1
fi

# Wyświetl projekty
PROJECT_COUNT=$(echo "$PROJECTS" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")

echo "Znaleziono projektów: $PROJECT_COUNT"
echo ""

if [ "$PROJECT_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}Nie masz jeszcze żadnych projektów.${NC}"
    echo "Utwórz projekt: https://supabase.com/dashboard"
    exit 0
fi

# Wyświetl projekty do wyboru
echo "Wybierz projekt do testowania:"
echo ""

COUNTER=1
declare -a PROJECT_REFS

echo "$PROJECTS" | python3 -c "
import sys, json
for proj in json.load(sys.stdin):
    print(f'{proj.get(\"name\", \"N/A\")} ({proj.get(\"id\", \"N/A\")})')
" | while read -r line; do
    echo "  $COUNTER) $line"
    COUNTER=$((COUNTER + 1))
done

# Zapisz refs do tablicy
while IFS= read -r ref; do
    PROJECT_REFS+=("$ref")
done < <(echo "$PROJECTS" | python3 -c "import sys, json; [print(p['id']) for p in json.load(sys.stdin)]")

echo ""
read -p "Wybierz numer [1-$PROJECT_COUNT]: " CHOICE

if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$PROJECT_COUNT" ]; then
    echo -e "${RED}❌ Nieprawidłowy wybór${NC}"
    exit 1
fi

# Pobierz wybrany ref (Python liczy od 0)
PROJECT_REF=$(echo "$PROJECTS" | python3 -c "import sys, json; print(json.load(sys.stdin)[$((CHOICE - 1))]['id'])")

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🔑 TEST: Pobieranie kluczy dla projektu $PROJECT_REF"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Test 1: BEZ reveal parameter
echo "📋 Test 1: Pobieranie BEZ parametru ?reveal (stary sposób)"
echo ""

API_KEYS_NO_REVEAL=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" \
    "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys")

# Sprawdź czy są zamaskowane
SECRET_KEY_NO_REVEAL=$(echo "$API_KEYS_NO_REVEAL" | python3 -c "
import sys, json
try:
    for key in json.load(sys.stdin):
        if key.get('type') == 'secret':
            print(key.get('api_key', ''))
            break
except:
    pass
")

if [[ "$SECRET_KEY_NO_REVEAL" =~ ··· ]]; then
    echo -e "${YELLOW}   ⚠️  Secret key jest ZAMASKOWANY (oczekiwane)${NC}"
    echo "      $SECRET_KEY_NO_REVEAL"
else
    echo -e "${GREEN}   ✓ Secret key jest pełny (legacy projekt)${NC}"
    echo "      ${SECRET_KEY_NO_REVEAL:0:30}..."
fi

echo ""

# Test 2: Z reveal parameter
echo "📋 Test 2: Pobieranie Z parametrem ?reveal=true (nowy sposób)"
echo ""

API_KEYS_WITH_REVEAL=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" \
    "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys?reveal=true")

# Sprawdź czy są pełne
SECRET_KEY_WITH_REVEAL=$(echo "$API_KEYS_WITH_REVEAL" | python3 -c "
import sys, json
try:
    for key in json.load(sys.stdin):
        if key.get('type') == 'secret':
            print(key.get('api_key', ''))
            break
except:
    pass
")

if [[ "$SECRET_KEY_WITH_REVEAL" =~ ··· ]]; then
    echo -e "${RED}   ❌ Secret key NADAL zamaskowany (problem!)${NC}"
    echo "      $SECRET_KEY_WITH_REVEAL"
    echo ""
    echo "Może token nie ma uprawnień do 'reveal'?"
else
    echo -e "${GREEN}   ✅ Secret key jest PEŁNY!${NC}"
    echo "      ${SECRET_KEY_WITH_REVEAL:0:30}..."
fi

echo ""

# Podsumowanie
echo "════════════════════════════════════════════════════════════════"
echo "📊 PODSUMOWANIE"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [[ "$SECRET_KEY_NO_REVEAL" =~ ··· ]] && [[ ! "$SECRET_KEY_WITH_REVEAL" =~ ··· ]]; then
    echo -e "${GREEN}✅ SUKCES! Parametr ?reveal=true działa poprawnie!${NC}"
    echo ""
    echo "   BEZ reveal:  zamaskowany (stary endpoint)"
    echo "   Z reveal:    pełny klucz ✓"
    echo ""
    echo "Deploy.sh będzie działać automatycznie z nowymi projektami! 🎉"
elif [[ ! "$SECRET_KEY_NO_REVEAL" =~ ··· ]]; then
    echo -e "${BLUE}ℹ️  To jest legacy projekt${NC}"
    echo ""
    echo "   Legacy projekty zwracają pełne klucze nawet bez ?reveal=true"
    echo "   Deploy.sh będzie działać poprawnie."
else
    echo -e "${YELLOW}⚠️  Oba endpointy zwracają zamaskowane klucze${NC}"
    echo ""
    echo "Możliwe przyczyny:"
    echo "   • Token nie ma uprawnień do 'reveal'"
    echo "   • Nowy projekt wymaga innych uprawnień"
    echo ""
    echo "Skontaktuj się z supportem Supabase."
fi

echo ""
