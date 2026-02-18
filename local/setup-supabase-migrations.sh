#!/bin/bash

# Mikrus Toolbox - Supabase Migrations (via API)
# Przygotowuje bazę danych dla GateFlow
# Author: Paweł (Lazy Engineer)
#
# Używa Supabase Management API - nie wymaga DATABASE_URL ani psql
# Potrzebuje tylko SUPABASE_URL i Personal Access Token
#
# Użycie:
#   ./local/setup-supabase-migrations.sh
#
# Zmienne środowiskowe (opcjonalne - można podać interaktywnie):
#   SUPABASE_URL - URL projektu (https://xxx.supabase.co)
#   SUPABASE_ACCESS_TOKEN - Personal Access Token

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

GITHUB_REPO="jurczykpawel/gateflow"
MIGRATIONS_PATH="supabase/migrations"

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Konfiguracja
CONFIG_DIR="$HOME/.config/gateflow"
CONFIG_FILE="$CONFIG_DIR/supabase.env"

echo ""
echo -e "${BLUE}🗄️  Przygotowanie bazy danych${NC}"
echo ""

# =============================================================================
# 1. POBIERZ KONFIGURACJĘ
# =============================================================================

# Zachowaj wartości z env (mają priorytet nad config)
ENV_PROJECT_REF="$PROJECT_REF"
ENV_SUPABASE_URL="$SUPABASE_URL"

# Załaduj zapisaną konfigurację
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Przywróć wartości z env jeśli były ustawione (env > config)
[ -n "$ENV_PROJECT_REF" ] && PROJECT_REF="$ENV_PROJECT_REF"
[ -n "$ENV_SUPABASE_URL" ] && SUPABASE_URL="$ENV_SUPABASE_URL"

# Sprawdź SUPABASE_URL
if [ -z "$SUPABASE_URL" ]; then
    echo -e "${RED}❌ Brak SUPABASE_URL${NC}"
    echo "   Najpierw uruchom instalację GateFlow lub setup-supabase-gateflow.sh"
    exit 1
fi

# Użyj PROJECT_REF z config lub wyciągnij z URL
if [ -z "$PROJECT_REF" ]; then
    PROJECT_REF=$(echo "$SUPABASE_URL" | sed -E 's|https://([^.]+)\.supabase\.co.*|\1|')
fi

if [ -z "$PROJECT_REF" ] || [ "$PROJECT_REF" = "$SUPABASE_URL" ]; then
    echo -e "${RED}❌ Nie mogę wyciągnąć project ref z URL: $SUPABASE_URL${NC}"
    exit 1
fi

echo "   Projekt: $PROJECT_REF"

# Sprawdź Personal Access Token
if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
    # Sprawdź w głównym configu cloudflare (gdzie zapisujemy tokeny)
    SUPABASE_TOKEN_FILE="$HOME/.config/supabase/access_token"
    if [ -f "$SUPABASE_TOKEN_FILE" ]; then
        SUPABASE_ACCESS_TOKEN=$(cat "$SUPABASE_TOKEN_FILE")
    fi
fi

if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
    echo ""
    echo -e "${YELLOW}⚠️  Brak Personal Access Token${NC}"
    echo ""
    echo "Potrzebuję tokena do wykonania zmian w bazie danych."
    echo ""
    echo "Gdzie go znaleźć:"
    echo "   1. Otwórz: https://supabase.com/dashboard/account/tokens"
    echo "   2. Kliknij 'Generate new token'"
    echo "   3. Skopiuj token"
    echo ""

    read -p "Naciśnij Enter aby otworzyć Supabase..." _
    if command -v open &>/dev/null; then
        open "https://supabase.com/dashboard/account/tokens"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "https://supabase.com/dashboard/account/tokens"
    fi

    echo ""
    read -p "Wklej Personal Access Token: " SUPABASE_ACCESS_TOKEN

    if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
        echo -e "${RED}❌ Token jest wymagany${NC}"
        exit 1
    fi

    # Zapisz token
    mkdir -p "$HOME/.config/supabase"
    echo "$SUPABASE_ACCESS_TOKEN" > "$SUPABASE_TOKEN_FILE"
    chmod 600 "$SUPABASE_TOKEN_FILE"
    echo "   ✅ Token zapisany"
fi

# =============================================================================
# 2. FUNKCJA DO WYKONYWANIA SQL
# =============================================================================

run_sql() {
    local SQL="$1"

    RESPONSE=$(curl -s -X POST "https://api.supabase.com/v1/projects/$PROJECT_REF/database/query" \
        -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"query\": $(echo "$SQL" | jq -Rs .)}")

    # Sprawdź błędy
    if echo "$RESPONSE" | grep -q '"error"'; then
        ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        echo -e "${RED}❌ Błąd SQL: $ERROR${NC}" >&2
        return 1
    fi

    echo "$RESPONSE"
}

# Test połączenia
echo ""
echo "🔍 Sprawdzam połączenie z bazą..."

TEST_RESULT=$(run_sql "SELECT 1 as test" 2>&1)
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Nie mogę połączyć się z bazą${NC}"
    echo "   Sprawdź czy token jest prawidłowy"
    exit 1
fi

echo -e "${GREEN}✅ Połączenie OK${NC}"

# =============================================================================
# 3. ZNAJDŹ MIGRACJE (lokalnie lub z GitHub)
# =============================================================================

echo ""
echo "📥 Szukam plików migracji..."

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Sprawdź czy migracje są na serwerze (z paczki instalacyjnej)
SSH_ALIAS="${SSH_ALIAS:-mikrus}"
MIGRATIONS_SOURCE=""

# Znajdź katalog instalacji GateFlow
# Nowa lokalizacja: /opt/stacks/gateflow*
# Stara lokalizacja: /root/gateflow* (dla kompatybilności)
GATEFLOW_DIR=$(server_exec "ls -d /opt/stacks/gateflow-* 2>/dev/null | head -1" 2>/dev/null)
if [ -z "$GATEFLOW_DIR" ]; then
    GATEFLOW_DIR=$(server_exec "ls -d /opt/stacks/gateflow 2>/dev/null" 2>/dev/null)
fi
if [ -z "$GATEFLOW_DIR" ]; then
    # Fallback do starej lokalizacji
    GATEFLOW_DIR=$(server_exec "ls -d /root/gateflow-* 2>/dev/null | head -1" 2>/dev/null)
fi
if [ -z "$GATEFLOW_DIR" ]; then
    GATEFLOW_DIR="/root/gateflow"
fi
REMOTE_MIGRATIONS_DIR="$GATEFLOW_DIR/admin-panel/supabase/migrations"

# Pobierz listę migracji z serwera przez SSH
MIGRATIONS_LIST=$(server_exec "ls '$REMOTE_MIGRATIONS_DIR'/*.sql 2>/dev/null | xargs -n1 basename 2>/dev/null | sort" 2>/dev/null)

if [ -n "$MIGRATIONS_LIST" ]; then
    echo "   ✅ Znaleziono migracje w paczce instalacyjnej"
    MIGRATIONS_SOURCE="server"
    # Skopiuj z serwera do temp
    if is_on_server; then
        cp "$REMOTE_MIGRATIONS_DIR/"*.sql "$TEMP_DIR/" 2>/dev/null
    else
        scp -q "$SSH_ALIAS:$REMOTE_MIGRATIONS_DIR/"*.sql "$TEMP_DIR/" 2>/dev/null
    fi
fi

# Fallback - pobierz z GitHub
if [ -z "$MIGRATIONS_SOURCE" ]; then
    echo "   Pobieram z GitHub..."
    MIGRATIONS_LIST=$(curl -sL "https://api.github.com/repos/$GITHUB_REPO/contents/$MIGRATIONS_PATH" \
        -H "Authorization: token ${GITHUB_TOKEN:-}" 2>/dev/null | grep -o '"name": "[^"]*\.sql"' | cut -d'"' -f4 | sort)

    if [ -z "$MIGRATIONS_LIST" ]; then
        echo -e "${YELLOW}⚠️  Brak migracji do wykonania${NC}"
        echo "   Migracje nie są dostępne lokalnie ani na GitHub."
        exit 0
    fi

    # Pobierz każdy plik
    for migration in $MIGRATIONS_LIST; do
        curl -sL "https://raw.githubusercontent.com/$GITHUB_REPO/main/$MIGRATIONS_PATH/$migration" \
            -H "Authorization: token ${GITHUB_TOKEN:-}" \
            -o "$TEMP_DIR/$migration"
    done
    MIGRATIONS_SOURCE="github"
fi

echo "   Znaleziono migracje:"
for migration in $MIGRATIONS_LIST; do
    echo "   - $migration"
done

# =============================================================================
# 4. SPRAWDŹ KTÓRE MIGRACJE SĄ POTRZEBNE
# =============================================================================

echo ""
echo "🔍 Sprawdzam status bazy..."

# Używamy tabeli Supabase CLI: supabase_migrations.schema_migrations
# Dzięki temu migracje są spójne z `supabase migration up`
APPLIED_MIGRATIONS=""

# Sprawdź czy schema supabase_migrations istnieje
SCHEMA_CHECK=$(run_sql "SELECT EXISTS (SELECT FROM information_schema.schemata WHERE schema_name = 'supabase_migrations');" 2>/dev/null)

if echo "$SCHEMA_CHECK" | grep -q "true"; then
    echo "   Tabela migracji Supabase istnieje"
    APPLIED_RESULT=$(run_sql "SELECT version FROM supabase_migrations.schema_migrations ORDER BY version;" 2>/dev/null)
    APPLIED_MIGRATIONS=$(echo "$APPLIED_RESULT" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')

    if [ -n "$APPLIED_MIGRATIONS" ]; then
        echo "   Już zaaplikowane: $(echo $APPLIED_MIGRATIONS | wc -w | tr -d ' ') migracji"
    fi
else
    echo "   Świeża instalacja - tworzę tabelę migracji..."
    # Utwórz schema i tabelę zgodną z Supabase CLI
    run_sql "CREATE SCHEMA IF NOT EXISTS supabase_migrations;" > /dev/null
    run_sql "CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (version TEXT PRIMARY KEY, name TEXT, statements TEXT[]);" > /dev/null
    echo "   ✅ Utworzono supabase_migrations.schema_migrations"
fi

# Określ które migracje trzeba wykonać
PENDING_MIGRATIONS=""
for migration in $MIGRATIONS_LIST; do
    VERSION=$(echo "$migration" | cut -d'_' -f1)
    if ! echo "$APPLIED_MIGRATIONS" | grep -q "$VERSION"; then
        PENDING_MIGRATIONS="$PENDING_MIGRATIONS $migration"
    fi
done

PENDING_MIGRATIONS=$(echo "$PENDING_MIGRATIONS" | xargs)

if [ -z "$PENDING_MIGRATIONS" ]; then
    echo ""
    echo -e "${GREEN}✅ Baza danych jest aktualna${NC}"
    exit 0
fi

echo ""
echo "📋 Do wykonania:"
for migration in $PENDING_MIGRATIONS; do
    echo -e "   ${YELLOW}→ $migration${NC}"
done

# =============================================================================
# 5. WYKONAJ MIGRACJE
# =============================================================================

echo ""
echo "🚀 Wykonuję..."

for migration in $PENDING_MIGRATIONS; do
    VERSION=$(echo "$migration" | cut -d'_' -f1)
    echo -n "   $migration... "

    SQL_CONTENT=$(cat "$TEMP_DIR/$migration")

    if run_sql "$SQL_CONTENT" > /dev/null 2>&1; then
        # Zapisz w tabeli Supabase CLI
        NAME=$(echo "$migration" | sed 's/^[0-9]*_//' | sed 's/\.sql$//')
        run_sql "INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES ('$VERSION', '$NAME');" > /dev/null 2>&1
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
        echo -e "${RED}   Błąd w migracji $migration${NC}"
        exit 1
    fi
done

echo ""
echo -e "${GREEN}🎉 Baza danych przygotowana!${NC}"
