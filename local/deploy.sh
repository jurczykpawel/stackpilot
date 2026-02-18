#!/bin/bash

# Mikrus Toolbox - Remote Deployer
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   ./local/deploy.sh APP [--ssh=ALIAS] [--db-source=shared|custom] [--domain=DOMAIN] [--yes]
#
# Przykłady:
#   ./local/deploy.sh n8n --ssh=mikrus                              # interaktywny
#   ./local/deploy.sh n8n --ssh=mikrus --db-source=shared --domain=auto --yes  # automatyczny
#   ./local/deploy.sh uptime-kuma --domain-type=local --yes        # bez domeny
#
# FLOW:
#   1. Parsowanie argumentów CLI
#   2. Potwierdzenie użytkownika (skip z --yes)
#   3. FAZA ZBIERANIA - pytania o DB i domenę (skip z CLI)
#   4. "Teraz się zrelaksuj - pracuję..."
#   5. FAZA WYKONANIA - API calls, Docker, instalacja
#   6. Konfiguracja domeny (PO uruchomieniu usługi!)
#   7. Podsumowanie

set -e

# Znajdź katalog repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Załaduj biblioteki
source "$REPO_ROOT/lib/cli-parser.sh"
source "$REPO_ROOT/lib/db-setup.sh"
source "$REPO_ROOT/lib/domain-setup.sh"
source "$REPO_ROOT/lib/gateflow-setup.sh" 2>/dev/null || true  # Opcjonalna dla GateFlow
source "$REPO_ROOT/lib/port-utils.sh"

# Placeholder wstawiany do docker-compose gdy DOMAIN="-" (automatyczny Cytrus).
# Po przydzieleniu domeny przez Cytrus API, sed zamienia placeholder na prawdziwą domenę.
CYTRUS_PLACEHOLDER="__CYTRUS_PENDING__"

# =============================================================================
# CUSTOM HELP
# =============================================================================

show_deploy_help() {
    cat <<EOF
Mikrus Toolbox - Deploy

Użycie:
  ./local/deploy.sh APP [opcje]

Argumenty:
  APP                  Nazwa aplikacji (np. n8n, uptime-kuma) lub ścieżka do skryptu

Opcje SSH:
  --ssh=ALIAS          SSH alias z ~/.ssh/config (domyślnie: mikrus)

Opcje bazy danych:
  --db-source=TYPE     Źródło bazy: shared (API Mikrus) lub custom
  --db-host=HOST       Host bazy danych
  --db-port=PORT       Port bazy (domyślnie: 5432)
  --db-name=NAME       Nazwa bazy danych
  --db-schema=SCHEMA   Schema PostgreSQL (domyślnie: public)
  --db-user=USER       Użytkownik bazy
  --db-pass=PASS       Hasło bazy

Opcje domeny:
  --domain=DOMAIN      Domena aplikacji (lub 'auto' dla Cytrus automatyczny)
  --domain-type=TYPE   Typ: cytrus, cloudflare, local

Tryby:
  --yes, -y            Pomiń wszystkie potwierdzenia
  --dry-run            Pokaż co się wykona bez wykonania
  --update             Aktualizuj istniejącą aplikację (zamiast instalować)
  --restart            Restart bez aktualizacji (np. po zmianie .env) - używany z --update
  --build-file=PATH    Użyj lokalnego pliku tar.gz (dla --update, gdy repo jest prywatne)
  --help, -h           Pokaż tę pomoc

Przykłady:
  # Interaktywny (pytania o brakujące dane)
  ./local/deploy.sh n8n --ssh=mikrus

  # Automatyczny z Cytrus
  ./local/deploy.sh uptime-kuma --ssh=mikrus --domain-type=cytrus --domain=auto --yes

  # Automatyczny z Cloudflare
  ./local/deploy.sh n8n --ssh=mikrus \\
    --db-source=custom --db-host=psql.example.com \\
    --db-name=n8n --db-user=user --db-pass=secret \\
    --domain-type=cloudflare --domain=n8n.example.com --yes

  # Tylko lokalnie (bez domeny)
  ./local/deploy.sh dockge --ssh=mikrus --domain-type=local --yes

  # Dry-run (podgląd bez wykonania)
  ./local/deploy.sh n8n --ssh=mikrus --dry-run

  # Aktualizacja istniejącej aplikacji
  ./local/deploy.sh gateflow --ssh=mikrus --update

  # Aktualizacja z lokalnego pliku (gdy repo jest prywatne)
  ./local/deploy.sh gateflow --ssh=mikrus --update --build-file=~/Downloads/gateflow-build.tar.gz

  # Restart bez aktualizacji (np. po zmianie .env)
  ./local/deploy.sh gateflow --ssh=mikrus --update --restart

EOF
}

# Override show_help z cli-parser
show_help() {
    show_deploy_help
}

# =============================================================================
# PARSOWANIE ARGUMENTÓW
# =============================================================================

load_defaults
parse_args "$@"

# Pierwszy argument pozycyjny = APP
SCRIPT_PATH="${POSITIONAL_ARGS[0]:-}"

if [ -z "$SCRIPT_PATH" ]; then
    echo "Błąd: Nie podano nazwy aplikacji."
    echo ""
    show_deploy_help
    exit 1
fi

# SSH_ALIAS z --ssh lub default
SSH_ALIAS="${SSH_ALIAS:-mikrus}"

# =============================================================================
# SPRAWDZANIE POŁĄCZENIA SSH
# =============================================================================

if ! is_on_server; then
    # Sprawdź czy alias SSH jest skonfigurowany (ssh -G parsuje config bez łączenia)
    _SSH_RESOLVED_HOST=$(ssh -G "$SSH_ALIAS" 2>/dev/null | awk '/^hostname / {print $2}')

    if [ -z "$_SSH_RESOLVED_HOST" ] || [ "$_SSH_RESOLVED_HOST" = "$SSH_ALIAS" ]; then
        # Alias nie jest skonfigurowany w ~/.ssh/config
        echo ""
        echo -e "${RED}❌ Alias SSH '$SSH_ALIAS' nie jest skonfigurowany${NC}"
        echo ""
        echo "   Potrzebujesz danych z maila od Mikrusa: host, port i hasło."
        echo ""

        SETUP_SCRIPT="$REPO_ROOT/local/setup-ssh.sh"
        if [[ "$IS_GITBASH" == "true" ]] || [[ "$YES_MODE" == "true" ]]; then
            # Windows (Git Bash) lub tryb --yes — pokaż instrukcje
            echo "   Uruchom konfigurację SSH:"
            echo -e "   ${BLUE}bash local/setup-ssh.sh${NC}"
            exit 1
        elif [ -f "$SETUP_SCRIPT" ]; then
            # macOS/Linux — zaproponuj automatyczne uruchomienie
            if confirm "   Skonfigurować połączenie SSH teraz?"; then
                echo ""
                bash "$SETUP_SCRIPT"
                # Po konfiguracji sprawdź ponownie
                if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_ALIAS" "echo ok" &>/dev/null; then
                    echo ""
                    echo -e "${RED}❌ Połączenie nadal nie działa. Sprawdź dane i spróbuj ponownie.${NC}"
                    exit 1
                fi
            else
                exit 1
            fi
        else
            echo "   Skonfiguruj SSH:"
            echo -e "   ${BLUE}bash <(curl -s https://raw.githubusercontent.com/jurczykpawel/mikrus-toolbox/main/local/setup-ssh.sh)${NC}"
            exit 1
        fi
    else
        # Alias skonfigurowany — sprawdź czy połączenie działa
        echo -n "🔗 Sprawdzam połączenie SSH ($SSH_ALIAS)... "
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_ALIAS" "echo ok" &>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
            echo ""
            echo -e "${RED}❌ Nie mogę połączyć się z serwerem '$SSH_ALIAS' ($_SSH_RESOLVED_HOST)${NC}"
            echo ""
            echo "   Możliwe przyczyny:"
            echo "   - Serwer jest wyłączony lub nie odpowiada"
            echo "   - Klucz SSH nie jest autoryzowany na serwerze"
            echo "   - Nieprawidłowy host lub port w ~/.ssh/config"
            echo ""
            echo "   Diagnostyka:"
            echo -e "   ${BLUE}ssh -v $SSH_ALIAS${NC}"
            echo ""
            echo "   Ponowna konfiguracja:"
            echo -e "   ${BLUE}bash local/setup-ssh.sh${NC}"
            exit 1
        fi
    fi
fi

# =============================================================================
# ZAŁADUJ ZAPISANĄ KONFIGURACJĘ (dla GateFlow)
# =============================================================================

GATEFLOW_CONFIG="$HOME/.config/gateflow/deploy-config.env"
if [ -f "$GATEFLOW_CONFIG" ] && [[ "$SCRIPT_PATH" == "gateflow" ]]; then
    # Zachowaj wartości z CLI (mają priorytet nad configiem)
    CLI_SSH_ALIAS="$SSH_ALIAS"
    CLI_DOMAIN="$DOMAIN"
    CLI_DOMAIN_TYPE="$DOMAIN_TYPE"
    CLI_SUPABASE_PROJECT="$SUPABASE_PROJECT"

    # Załaduj config
    source "$GATEFLOW_CONFIG"

    # Przywróć wartości CLI jeśli były podane (CLI > config)
    [ -n "$CLI_SSH_ALIAS" ] && SSH_ALIAS="$CLI_SSH_ALIAS"
    [ -n "$CLI_DOMAIN" ] && DOMAIN="$CLI_DOMAIN"
    [ -n "$CLI_DOMAIN_TYPE" ] && DOMAIN_TYPE="$CLI_DOMAIN_TYPE"
    [ -n "$CLI_SUPABASE_PROJECT" ] && SUPABASE_PROJECT="$CLI_SUPABASE_PROJECT"

    if [ "$YES_MODE" = true ]; then
        # Tryb --yes: używaj zapisanej konfiguracji (z override z CLI)
        echo "📂 Ładuję zapisaną konfigurację GateFlow (tryb --yes)..."

        # Supabase
        [ -n "$SUPABASE_URL" ] && export SUPABASE_URL
        [ -n "$PROJECT_REF" ] && export PROJECT_REF
        [ -n "$SUPABASE_ANON_KEY" ] && export SUPABASE_ANON_KEY
        [ -n "$SUPABASE_SERVICE_KEY" ] && export SUPABASE_SERVICE_KEY

        # Stripe
        [ -n "$STRIPE_PK" ] && export STRIPE_PK
        [ -n "$STRIPE_SK" ] && export STRIPE_SK
        [ -n "$STRIPE_WEBHOOK_SECRET" ] && export STRIPE_WEBHOOK_SECRET

        # Turnstile
        [ -n "$CLOUDFLARE_TURNSTILE_SITE_KEY" ] && export CLOUDFLARE_TURNSTILE_SITE_KEY
        [ -n "$CLOUDFLARE_TURNSTILE_SECRET_KEY" ] && export CLOUDFLARE_TURNSTILE_SECRET_KEY

        echo "   ✅ Konfiguracja załadowana"
    else
        # Tryb interaktywny: pytaj o wszystko, tylko zachowaj token Supabase
        echo "📂 Tryb interaktywny - będę pytać o konfigurację"

        # Wyczyść wszystko oprócz tokena (żeby nie trzeba było się ponownie logować)
        unset SUPABASE_URL PROJECT_REF SUPABASE_ANON_KEY SUPABASE_SERVICE_KEY
        unset STRIPE_PK STRIPE_SK STRIPE_WEBHOOK_SECRET
        unset CLOUDFLARE_TURNSTILE_SITE_KEY CLOUDFLARE_TURNSTILE_SECRET_KEY
        unset DOMAIN DOMAIN_TYPE
    fi
fi

# =============================================================================
# TRYB AKTUALIZACJI (--update)
# =============================================================================

if [ "$UPDATE_MODE" = true ]; then
    APP_NAME="$SCRIPT_PATH"

    # Sprawdź czy aplikacja ma skrypt update.sh
    UPDATE_SCRIPT="$REPO_ROOT/apps/$APP_NAME/update.sh"
    if [ ! -f "$UPDATE_SCRIPT" ]; then
        echo -e "${RED}❌ Aplikacja '$APP_NAME' nie ma skryptu aktualizacji${NC}"
        echo "   Brak: apps/$APP_NAME/update.sh"
        exit 1
    fi

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  🔄 AKTUALIZACJA: $APP_NAME"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Serwer: $SSH_ALIAS"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    if ! confirm "Zaktualizować $APP_NAME na serwerze $SSH_ALIAS?"; then
        echo "Anulowano."
        exit 0
    fi

    echo ""
    echo "🚀 Uruchamiam aktualizację..."

    # Skopiuj skrypt na serwer
    REMOTE_SCRIPT="/tmp/mikrus-update-$$.sh"
    server_copy "$UPDATE_SCRIPT" "$REMOTE_SCRIPT"

    # Jeśli mamy lokalny plik builda, skopiuj go na serwer
    REMOTE_BUILD_FILE=""
    if [ -n "$BUILD_FILE" ]; then
        # Rozwiń ~ do pełnej ścieżki
        BUILD_FILE="${BUILD_FILE/#\~/$HOME}"

        if [ ! -f "$BUILD_FILE" ]; then
            echo -e "${RED}❌ Plik nie istnieje: $BUILD_FILE${NC}"
            exit 1
        fi

        echo "📤 Kopiuję plik buildu na serwer..."
        REMOTE_BUILD_FILE="/tmp/gateflow-build-$$.tar.gz"
        server_copy "$BUILD_FILE" "$REMOTE_BUILD_FILE"
        echo "   ✅ Skopiowano"
    fi

    # Przekaż zmienne środowiskowe
    ENV_VARS="SKIP_MIGRATIONS=1"  # Migracje uruchomimy lokalnie przez API
    if [ -n "$REMOTE_BUILD_FILE" ]; then
        ENV_VARS="$ENV_VARS BUILD_FILE='$REMOTE_BUILD_FILE'"
    fi

    # Dla multi-instance: przekaż nazwę instancji (z --instance lub --domain)
    if [ -n "$INSTANCE" ]; then
        ENV_VARS="$ENV_VARS INSTANCE='$INSTANCE'"
    elif [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
        # Wyznacz instancję z domeny
        UPDATE_INSTANCE="${DOMAIN%%.*}"
        ENV_VARS="$ENV_VARS INSTANCE='$UPDATE_INSTANCE'"
    fi

    # Przygotuj argumenty dla update.sh
    UPDATE_SCRIPT_ARGS=""
    if [ "$RESTART_ONLY" = true ]; then
        UPDATE_SCRIPT_ARGS="--restart"
    fi

    # Uruchom skrypt i posprzątaj
    CLEANUP_CMD="rm -f '$REMOTE_SCRIPT'"
    if [ -n "$REMOTE_BUILD_FILE" ]; then
        CLEANUP_CMD="$CLEANUP_CMD '$REMOTE_BUILD_FILE'"
    fi

    if server_exec_tty "export $ENV_VARS; bash '$REMOTE_SCRIPT' $UPDATE_SCRIPT_ARGS; EXIT_CODE=\$?; $CLEANUP_CMD; exit \$EXIT_CODE"; then
        echo ""
        if [ "$RESTART_ONLY" = true ]; then
            echo -e "${GREEN}✅ GateFlow zrestartowany!${NC}"
        else
            echo -e "${GREEN}✅ Pliki zaktualizowane${NC}"
        fi
    else
        echo ""
        echo -e "${RED}❌ Aktualizacja nie powiodła się${NC}"
        exit 1
    fi

    # Dla GateFlow - uruchom migracje przez API (lokalnie) - tylko w trybie update, nie restart
    if [ "$APP_NAME" = "gateflow" ] && [ "$RESTART_ONLY" = false ]; then
        echo ""
        echo "🗄️  Aktualizuję bazę danych..."

        if [ -f "$REPO_ROOT/local/setup-supabase-migrations.sh" ]; then
            SSH_ALIAS="$SSH_ALIAS" "$REPO_ROOT/local/setup-supabase-migrations.sh" || true
        fi
    fi

    echo ""
    if [ "$RESTART_ONLY" = true ]; then
        echo -e "${GREEN}✅ Restart zakończony!${NC}"
    else
        echo -e "${GREEN}✅ Aktualizacja zakończona!${NC}"
    fi

    exit 0
fi

# =============================================================================
# RESOLVE APP/SCRIPT PATH
# =============================================================================

APP_NAME=""
if [ -f "$REPO_ROOT/apps/$SCRIPT_PATH/install.sh" ]; then
    echo "💡 Wykryto aplikację: '$SCRIPT_PATH'"
    APP_NAME="$SCRIPT_PATH"
    SCRIPT_PATH="$REPO_ROOT/apps/$SCRIPT_PATH/install.sh"
elif [ -f "$SCRIPT_PATH" ]; then
    :  # Direct file exists
elif [ -f "$REPO_ROOT/$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$REPO_ROOT/$SCRIPT_PATH"
else
    echo "Błąd: Skrypt lub aplikacja '$SCRIPT_PATH' nie znaleziona."
    echo "   Szukano:"
    echo "   - apps/$SCRIPT_PATH/install.sh"
    echo "   - $SCRIPT_PATH"
    exit 1
fi

# =============================================================================
# POTWIERDZENIE
# =============================================================================

REMOTE_HOST=$(server_hostname)
REMOTE_USER=$(server_user)
SCRIPT_DISPLAY="${SCRIPT_PATH#$REPO_ROOT/}"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
if is_on_server; then
echo "║  ⚠️   UWAGA: INSTALACJA NA TYM SERWERZE!                       ║"
else
echo "║  ⚠️   UWAGA: INSTALACJA NA ZDALNYM SERWERZE!                   ║"
fi
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  Serwer:  $REMOTE_USER@$REMOTE_HOST"
echo "║  Skrypt:  $SCRIPT_DISPLAY"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Ostrzeżenie dla Git Bash + MinTTY (przed interaktywnymi pytaniami)
warn_gitbash_mintty

if ! confirm "Czy na pewno chcesz uruchomić ten skrypt na ZDALNYM serwerze?"; then
    echo "Anulowano."
    exit 1
fi

# =============================================================================
# FAZA 0: SPRAWDZANIE ZASOBÓW SERWERA
# =============================================================================

# Wykryj wymagania RAM z docker-compose (memory limit)
REQUIRED_RAM=256  # domyślnie
if grep -q "memory:" "$SCRIPT_PATH" 2>/dev/null; then
    # Przenośna wersja (bez grep -P który nie działa na macOS)
    MEM_LIMIT=$(grep "memory:" "$SCRIPT_PATH" | sed -E 's/[^0-9]*([0-9]+).*/\1/' | head -1)
    if [ -n "$MEM_LIMIT" ]; then
        REQUIRED_RAM=$MEM_LIMIT
    fi
fi

# Wykryj rozmiar obrazu Docker
# 1. Próbuj Docker Hub API (dynamicznie)
# 2. Fallback na IMAGE_SIZE_MB z nagłówka skryptu
REQUIRED_DISK=500  # domyślnie 500MB
IMAGE_SIZE=""
IMAGE_SIZE_SOURCE=""

# Wyciągnij nazwę obrazu z docker-compose w skrypcie
DOCKER_IMAGE=$(grep -E "^[[:space:]]*image:" "$SCRIPT_PATH" 2>/dev/null | head -1 | awk -F'image:' '{gsub(/^[[:space:]]*|[[:space:]]*$/,"",$2); print $2}')

if [ -n "$DOCKER_IMAGE" ]; then
    # Tylko Docker Hub obsługuje nasze API query (nie ghcr.io, quay.io, etc.)
    if [[ "$DOCKER_IMAGE" != *"ghcr.io"* ]] && [[ "$DOCKER_IMAGE" != *"quay.io"* ]] && [[ "$DOCKER_IMAGE" != *"gcr.io"* ]]; then
        # Parsuj image name: owner/repo:tag lub library/repo:tag
        if [[ "$DOCKER_IMAGE" == *"/"* ]]; then
            REPO_OWNER=$(echo "$DOCKER_IMAGE" | cut -d'/' -f1)
            REPO_NAME=$(echo "$DOCKER_IMAGE" | cut -d'/' -f2 | cut -d':' -f1)
            TAG=$(echo "$DOCKER_IMAGE" | grep -o ':[^:]*$' | tr -d ':')
            [ -z "$TAG" ] && TAG="latest"
        else
            # Official image (e.g., redis:alpine)
            REPO_OWNER="library"
            REPO_NAME=$(echo "$DOCKER_IMAGE" | cut -d':' -f1)
            TAG=$(echo "$DOCKER_IMAGE" | grep -o ':[^:]*$' | tr -d ':')
            [ -z "$TAG" ] && TAG="latest"
        fi

        # Próbuj Docker Hub API (timeout 5s)
        API_URL="https://hub.docker.com/v2/repositories/${REPO_OWNER}/${REPO_NAME}/tags/${TAG}"
        COMPRESSED_SIZE=$(curl -sf --max-time 5 "$API_URL" 2>/dev/null | grep -o '"full_size":[0-9]*' | grep -o '[0-9]*')

        if [ -n "$COMPRESSED_SIZE" ] && [ "$COMPRESSED_SIZE" -gt 0 ]; then
            # Compressed * 2.5 ≈ uncompressed size on disk
            IMAGE_SIZE=$((COMPRESSED_SIZE / 1024 / 1024 * 25 / 10))
            IMAGE_SIZE_SOURCE="Docker Hub API"
        fi
    fi
fi

# Fallback na hardcoded IMAGE_SIZE_MB
if [ -z "$IMAGE_SIZE" ]; then
    IMAGE_SIZE=$(grep "^# IMAGE_SIZE_MB=" "$SCRIPT_PATH" 2>/dev/null | sed -E 's/.*IMAGE_SIZE_MB=([0-9]+).*/\1/' | head -1)
    [ -n "$IMAGE_SIZE" ] && IMAGE_SIZE_SOURCE="skrypt"
fi

if [ -n "$IMAGE_SIZE" ]; then
    # Dodaj 20% marginesu na temp files podczas pobierania
    REQUIRED_DISK=$((IMAGE_SIZE + IMAGE_SIZE / 5))
fi

# Sprawdź zasoby na serwerze
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  📊 Sprawdzanie zasobów serwera...                             ║"
echo "╚════════════════════════════════════════════════════════════════╝"

RESOURCES=$(server_exec_timeout 10 "free -m | awk '/^Mem:/ {print \$7}'; df -m / | awk 'NR==2 {print \$4}'; free -m | awk '/^Mem:/ {print \$2}'" 2>/dev/null)
AVAILABLE_RAM=$(echo "$RESOURCES" | sed -n '1p')
AVAILABLE_DISK=$(echo "$RESOURCES" | sed -n '2p')
TOTAL_RAM=$(echo "$RESOURCES" | sed -n '3p')

if [ -n "$AVAILABLE_RAM" ] && [ -n "$AVAILABLE_DISK" ]; then
    echo ""
    echo -n "   RAM: ${AVAILABLE_RAM}MB dostępne (z ${TOTAL_RAM}MB)"
    if [ "$AVAILABLE_RAM" -lt "$REQUIRED_RAM" ]; then
        echo -e " ${RED}✗ wymagane: ${REQUIRED_RAM}MB${NC}"
        if [ "$YES_MODE" != "true" ]; then
            echo ""
            echo -e "${RED}   ❌ Za mało RAM! Instalacja może zawiesić serwer.${NC}"
            if ! confirm "   Czy mimo to kontynuować?"; then
                echo "Anulowano."
                exit 1
            fi
        fi
    elif [ "$AVAILABLE_RAM" -lt $((REQUIRED_RAM + 100)) ]; then
        echo -e " ${YELLOW}⚠ będzie ciasno${NC}"
    else
        echo -e " ${GREEN}✓${NC}"
    fi

    echo -n "   Dysk: ${AVAILABLE_DISK}MB wolne"
    if [ "$AVAILABLE_DISK" -lt "$REQUIRED_DISK" ]; then
        echo -e " ${RED}✗ wymagane: ~${REQUIRED_DISK}MB${NC}"
        echo ""
        echo -e "${RED}   ❌ Za mało miejsca na dysku!${NC}"
        if [ -n "$IMAGE_SIZE_SOURCE" ]; then
            echo -e "${RED}   Obraz Docker: ~${IMAGE_SIZE}MB (${IMAGE_SIZE_SOURCE}) + temp files${NC}"
        else
            echo -e "${RED}   Obraz Docker zajmie ~500MB + temp files.${NC}"
        fi
        if [ "$YES_MODE" == "true" ]; then
            echo -e "${RED}   Przerywam instalację (--yes mode).${NC}"
            exit 1
        fi
        if ! confirm "   Czy mimo to kontynuować?"; then
            echo "Anulowano."
            exit 1
        fi
    elif [ "$AVAILABLE_DISK" -lt $((REQUIRED_DISK + 500)) ]; then
        echo -e " ${YELLOW}⚠ mało miejsca (potrzeba ~${REQUIRED_DISK}MB)${NC}"
    else
        echo -e " ${GREEN}✓${NC}"
    fi

    # Ostrzeżenie dla ciężkich aplikacji na małym RAM
    if [ "$REQUIRED_RAM" -ge 400 ] && [ "$TOTAL_RAM" -lt 2000 ]; then
        echo ""
        echo -e "   ${YELLOW}⚠ Ta aplikacja wymaga dużo RAM (${REQUIRED_RAM}MB).${NC}"
        echo -e "   ${YELLOW}  Zalecany plan: Mikrus 3.0+ (2GB RAM)${NC}"
    fi
else
    echo -e "   ${YELLOW}⚠ Nie udało się sprawdzić zasobów${NC}"
fi

# =============================================================================
# FAZA 0.5: SPRAWDZANIE PORTÓW
# =============================================================================

# Pobierz domyślny port z install.sh
# Obsługuje: PORT=3000 i PORT=${PORT:-3000}
DEFAULT_PORT=$(grep -E "^PORT=" "$SCRIPT_PATH" 2>/dev/null | head -1 | sed -E 's/.*[=:-]([0-9]+).*/\1/')
PORT_OVERRIDE=""

if [ -n "$DEFAULT_PORT" ]; then
    # Sprawdź czy port jest zajęty na serwerze
    PORT_IN_USE=$(server_exec_timeout 5 "ss -tlnp 2>/dev/null | grep -q ':${DEFAULT_PORT} ' && echo 'yes' || echo 'no'" 2>/dev/null)

    if [ "$PORT_IN_USE" == "yes" ]; then
        echo ""
        echo -e "   ${YELLOW}⚠ Port $DEFAULT_PORT jest zajęty!${NC}"

        # Jedno SSH → lista portów, szukanie w pamięci (bez limitu prób)
        PORT_OVERRIDE=$(find_free_port_remote "$SSH_ALIAS" $((DEFAULT_PORT + 1)))
        if [ -n "$PORT_OVERRIDE" ]; then
            echo -e "   ${GREEN}✓ Używam portu $PORT_OVERRIDE zamiast $DEFAULT_PORT${NC}"
        fi
    fi
fi

# =============================================================================
# FAZA 1: ZBIERANIE INFORMACJI (bez API/ciężkich operacji)
# =============================================================================

# Zmienne do przekazania
DB_ENV_VARS=""
DB_TYPE=""
NEEDS_DB=false
NEEDS_DOMAIN=false
APP_PORT=""

# Sprawdź czy aplikacja wymaga bazy danych
# WordPress z WP_DB_MODE=sqlite nie potrzebuje MySQL
if grep -qiE "DB_HOST|DATABASE_URL" "$SCRIPT_PATH" 2>/dev/null; then
    if [ "$APP_NAME" = "wordpress" ] && [ "$WP_DB_MODE" = "sqlite" ]; then
        echo ""
        echo -e "${GREEN}✅ WordPress w trybie SQLite — baza MySQL nie jest wymagana${NC}"
    else
        NEEDS_DB=true

        # Wykryj typ bazy
        if grep -qi "mysql" "$SCRIPT_PATH"; then
            DB_TYPE="mysql"
        elif grep -qi "mongo" "$SCRIPT_PATH"; then
            DB_TYPE="mongo"
        else
            DB_TYPE="postgres"
        fi

        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  🗄️  Ta aplikacja wymaga bazy danych ($DB_TYPE)                ║"
        echo "╚════════════════════════════════════════════════════════════════╝"

        if ! ask_database "$DB_TYPE" "$APP_NAME"; then
            echo "Błąd: Konfiguracja bazy danych nie powiodła się."
            exit 1
        fi
    fi
fi

# Sprawdź czy to aplikacja i wymaga domeny
if [[ "$SCRIPT_DISPLAY" == apps/* ]]; then
    APP_PORT=$(grep -E "^PORT=" "$SCRIPT_PATH" | head -1 | sed -E 's/.*[=:-]([0-9]+).*/\1/')

    # Sprawdź też czy skrypt wymaga DOMAIN (np. static sites bez Dockera)
    REQUIRES_DOMAIN_UPFRONT=false
    if grep -q 'if \[ -z "\$DOMAIN" \]' "$SCRIPT_PATH" 2>/dev/null; then
        REQUIRES_DOMAIN_UPFRONT=true
        APP_PORT="${APP_PORT:-443}"  # Static sites use HTTPS via Caddy
    fi

    if [ -n "$APP_PORT" ] || [ "$REQUIRES_DOMAIN_UPFRONT" = true ]; then
        NEEDS_DOMAIN=true

        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  🌐 Konfiguracja domeny dla: $APP_NAME                         ║"
        echo "╚════════════════════════════════════════════════════════════════╝"

        if ! ask_domain "$APP_NAME" "$APP_PORT" "$SSH_ALIAS"; then
            echo ""
            echo "Błąd: Konfiguracja domeny nie powiodła się."
            exit 1
        fi
    fi
fi

# =============================================================================
# FAZA 1.5: KONFIGURACJA GATEFLOW (pytania o Supabase)
# =============================================================================

# Zmienne GateFlow
GATEFLOW_TURNSTILE_SECRET=""
SETUP_TURNSTILE_LATER=false
TURNSTILE_OFFERED=false
GATEFLOW_STRIPE_CONFIGURED=false

if [ "$APP_NAME" = "gateflow" ]; then
    # 1. Zbierz konfigurację Supabase (token + wybór projektu)
    # Pobierz klucze jeśli:
    # - Nie mamy SUPABASE_URL, LUB
    # - Podano --supabase-project i jest inny niż aktualny PROJECT_REF
    NEED_SUPABASE_FETCH=false
    if [ -z "$SUPABASE_URL" ]; then
        NEED_SUPABASE_FETCH=true
    elif [ -n "$SUPABASE_PROJECT" ] && [ "$SUPABASE_PROJECT" != "$PROJECT_REF" ]; then
        # Podano inny projekt niż zapisany - musimy pobrać nowe klucze
        NEED_SUPABASE_FETCH=true
        echo "📦 Zmiana projektu Supabase: $PROJECT_REF → $SUPABASE_PROJECT"
    fi

    if [ "$NEED_SUPABASE_FETCH" = true ]; then
        if [ -n "$SUPABASE_PROJECT" ]; then
            # Podano --supabase-project - pobierz klucze automatycznie
            echo ""
            echo "📦 Konfiguracja Supabase (projekt: $SUPABASE_PROJECT)"

            # Upewnij się że mamy token
            if ! check_saved_supabase_token; then
                if ! supabase_manual_token_flow; then
                    echo "❌ Brak tokena Supabase"
                    exit 1
                fi
                save_supabase_token "$SUPABASE_TOKEN"
            fi

            if ! fetch_supabase_keys_by_ref "$SUPABASE_PROJECT"; then
                echo "❌ Nie udało się pobrać kluczy dla projektu: $SUPABASE_PROJECT"
                exit 1
            fi
        else
            # Interaktywny wybór projektu
            if ! gateflow_collect_config "$DOMAIN"; then
                echo "❌ Konfiguracja Supabase nie powiodła się"
                exit 1
            fi
        fi
    fi

    # 2. Zbierz konfigurację Stripe (pytanie lokalne)
    gateflow_collect_stripe_config
fi

# Turnstile dla GateFlow - pytanie o konfigurację CAPTCHA
# Turnstile działa na każdej domenie (nie tylko Cloudflare DNS), wymaga tylko konta Cloudflare
# Pomijamy tylko dla: local (dev) lub automatycznej domeny Cytrus (DOMAIN="-")
if [ "$APP_NAME" = "gateflow" ] && [ "$DOMAIN_TYPE" != "local" ] && [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    TURNSTILE_OFFERED=true
    echo ""
    echo "🔒 Konfiguracja Turnstile (CAPTCHA)"
    echo ""

    if [ "$YES_MODE" = true ]; then
        # W trybie --yes sprawdź czy mamy zapisane klucze
        KEYS_FILE="$HOME/.config/cloudflare/turnstile_keys_$DOMAIN"
        if [ -f "$KEYS_FILE" ]; then
            source "$KEYS_FILE"
            if [ -n "$CLOUDFLARE_TURNSTILE_SECRET_KEY" ]; then
                GATEFLOW_TURNSTILE_SECRET="$CLOUDFLARE_TURNSTILE_SECRET_KEY"
                echo "   ✅ Użyję zapisanych kluczy Turnstile"
            fi
        fi
        if [ -z "$GATEFLOW_TURNSTILE_SECRET" ]; then
            echo -e "${YELLOW}   ⚠️  Brak zapisanych kluczy Turnstile${NC}"
            echo "   Skonfiguruj po instalacji: ./local/setup-turnstile.sh $DOMAIN $SSH_ALIAS"
            SETUP_TURNSTILE_LATER=true
        fi
    else
        # Tryb interaktywny - zapytaj
        read -p "Skonfigurować Turnstile teraz? [T/n]: " SETUP_TURNSTILE
        if [[ ! "$SETUP_TURNSTILE" =~ ^[Nn]$ ]]; then
            if [ -f "$REPO_ROOT/local/setup-turnstile.sh" ]; then
                "$REPO_ROOT/local/setup-turnstile.sh" "$DOMAIN"

                # Czytaj klucze z zapisanego pliku
                KEYS_FILE="$HOME/.config/cloudflare/turnstile_keys_$DOMAIN"
                if [ -f "$KEYS_FILE" ]; then
                    source "$KEYS_FILE"
                    if [ -n "$CLOUDFLARE_TURNSTILE_SECRET_KEY" ]; then
                        GATEFLOW_TURNSTILE_SECRET="$CLOUDFLARE_TURNSTILE_SECRET_KEY"
                        EXTRA_ENV="$EXTRA_ENV CLOUDFLARE_TURNSTILE_SITE_KEY='$CLOUDFLARE_TURNSTILE_SITE_KEY' CLOUDFLARE_TURNSTILE_SECRET_KEY='$CLOUDFLARE_TURNSTILE_SECRET_KEY'"
                        echo -e "${GREEN}✅ Klucze Turnstile zostaną przekazane do instalacji${NC}"
                    fi
                fi
            else
                echo -e "${YELLOW}⚠️  Brak skryptu setup-turnstile.sh${NC}"
            fi
        else
            echo ""
            echo "⏭️  Pominięto. Możesz skonfigurować później:"
            echo "   ./local/setup-turnstile.sh $DOMAIN $SSH_ALIAS"
            SETUP_TURNSTILE_LATER=true
        fi
    fi
    echo ""
fi

# =============================================================================
# FAZA 2: WYKONANIE (ciężkie operacje)
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  ☕ Teraz się zrelaksuj - pracuję...                            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Pobierz dane bazy z API (jeśli shared)
if [ "$NEEDS_DB" = true ]; then
    if ! fetch_database "$DB_TYPE" "$SSH_ALIAS"; then
        echo "Błąd: Nie udało się pobrać danych bazy."
        exit 1
    fi

    # Sprawdź czy schemat już istnieje (ostrzeżenie dla użytkownika)
    if [ "$DB_TYPE" = "postgres" ]; then
        if ! warn_if_schema_exists "$SSH_ALIAS" "$APP_NAME"; then
            echo "Instalacja anulowana przez użytkownika."
            exit 1
        fi
    fi

    # Escape single quotes in DB_PASS (zapobieganie shell injection)
    ESCAPED_DB_PASS="${DB_PASS//\'/\'\\\'\'}"

    # Przygotuj zmienne środowiskowe
    DB_ENV_VARS="DB_HOST='$DB_HOST' DB_PORT='$DB_PORT' DB_NAME='$DB_NAME' DB_SCHEMA='$DB_SCHEMA' DB_USER='$DB_USER' DB_PASS='$ESCAPED_DB_PASS'"

    echo ""
    echo "📋 Baza danych:"
    echo "   Host: $DB_HOST"
    echo "   Baza: $DB_NAME"
    if [ -n "$DB_SCHEMA" ] && [ "$DB_SCHEMA" != "public" ]; then
        echo "   Schemat: $DB_SCHEMA"
    fi
    echo ""
fi

# Przygotuj zmienną DOMAIN do przekazania
# Przekaż domenę zawsze gdy jest dostępna — nawet w trybie local.
# install.sh używa domeny do nazewnictwa instancji (np. WordPress multi-instance).
DOMAIN_ENV=""
if [ "$NEEDS_DOMAIN" = true ] && [ -n "$DOMAIN" ]; then
    if [ "$DOMAIN" = "-" ]; then
        if [ "$DOMAIN_TYPE" = "local" ]; then
            # Tryb local bez konkretnej domeny — nic nie przekazuj
            :
        elif [ "$APP_NAME" = "gateflow" ]; then
            # GateFlow ma własny mechanizm — deploy.sh aktualizuje .env.local po Cytrus
            DOMAIN_ENV="DOMAIN='-'"
        else
            # Dla Cytrus z automatyczną domeną, przekaż placeholder zamiast "-".
            # install.sh zobaczy niepustą domenę i wstawi https://__CYTRUS_PENDING__ do docker-compose.
            # Po przydzieleniu domeny, sed zamieni placeholder na prawdziwą domenę (linia ~970).
            DOMAIN_ENV="DOMAIN='$CYTRUS_PLACEHOLDER'"
        fi
    else
        DOMAIN_ENV="DOMAIN='$DOMAIN'"
    fi
fi

# Przygotuj zmienną PORT do przekazania (jeśli nadpisany)
PORT_ENV=""
if [ -n "$PORT_OVERRIDE" ]; then
    PORT_ENV="PORT='$PORT_OVERRIDE'"
    # Zaktualizuj też APP_PORT dla configure_domain
    APP_PORT="$PORT_OVERRIDE"
fi

# Przekaż dodatkowe zmienne środowiskowe (dla specjalnych aplikacji jak Cap)
EXTRA_ENV=""
[ -n "$USE_LOCAL_MINIO" ] && EXTRA_ENV="$EXTRA_ENV USE_LOCAL_MINIO='$USE_LOCAL_MINIO'"
[ -n "$S3_ENDPOINT" ] && EXTRA_ENV="$EXTRA_ENV S3_ENDPOINT='$S3_ENDPOINT'"
[ -n "$S3_ACCESS_KEY" ] && EXTRA_ENV="$EXTRA_ENV S3_ACCESS_KEY='$S3_ACCESS_KEY'"
[ -n "$S3_SECRET_KEY" ] && EXTRA_ENV="$EXTRA_ENV S3_SECRET_KEY='$S3_SECRET_KEY'"
[ -n "$S3_BUCKET" ] && EXTRA_ENV="$EXTRA_ENV S3_BUCKET='$S3_BUCKET'"
[ -n "$S3_REGION" ] && EXTRA_ENV="$EXTRA_ENV S3_REGION='$S3_REGION'"
[ -n "$S3_PUBLIC_URL" ] && EXTRA_ENV="$EXTRA_ENV S3_PUBLIC_URL='$S3_PUBLIC_URL'"
[ -n "$MYSQL_ROOT_PASS" ] && EXTRA_ENV="$EXTRA_ENV MYSQL_ROOT_PASS='$MYSQL_ROOT_PASS'"
[ -n "$DOMAIN_PUBLIC" ] && EXTRA_ENV="$EXTRA_ENV DOMAIN_PUBLIC='$DOMAIN_PUBLIC'"
[ -n "$DOMAIN_TYPE" ] && EXTRA_ENV="$EXTRA_ENV DOMAIN_TYPE='$DOMAIN_TYPE'"
[ -n "$WP_DB_MODE" ] && EXTRA_ENV="$EXTRA_ENV WP_DB_MODE='$WP_DB_MODE'"

# Dla GateFlow - dodaj zmienne do EXTRA_ENV (zebrane wcześniej w FAZIE 1.5)
if [ "$APP_NAME" = "gateflow" ]; then
    # Supabase
    if [ -n "$SUPABASE_URL" ]; then
        EXTRA_ENV="$EXTRA_ENV SUPABASE_URL='$SUPABASE_URL' SUPABASE_ANON_KEY='$SUPABASE_ANON_KEY' SUPABASE_SERVICE_KEY='$SUPABASE_SERVICE_KEY'"
    fi

    # Stripe (jeśli zebrane lokalnie)
    if [ -n "$STRIPE_PK" ] && [ -n "$STRIPE_SK" ]; then
        EXTRA_ENV="$EXTRA_ENV STRIPE_PK='$STRIPE_PK' STRIPE_SK='$STRIPE_SK'"
        [ -n "$STRIPE_WEBHOOK_SECRET" ] && EXTRA_ENV="$EXTRA_ENV STRIPE_WEBHOOK_SECRET='$STRIPE_WEBHOOK_SECRET'"
    fi

    # Turnstile (jeśli zebrane)
    if [ -n "$GATEFLOW_TURNSTILE_SECRET" ]; then
        EXTRA_ENV="$EXTRA_ENV CLOUDFLARE_TURNSTILE_SITE_KEY='$CLOUDFLARE_TURNSTILE_SITE_KEY' CLOUDFLARE_TURNSTILE_SECRET_KEY='$CLOUDFLARE_TURNSTILE_SECRET_KEY'"
    fi
fi

# Dry-run mode
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run] Symulacja wykonania:${NC}"
    if is_on_server; then
        echo "  bash $SCRIPT_PATH"
        echo "  env: DEPLOY_SSH_ALIAS='$SSH_ALIAS' $PORT_ENV $DB_ENV_VARS $DOMAIN_ENV $EXTRA_ENV"
    else
        echo "  scp $SCRIPT_PATH $SSH_ALIAS:/tmp/mikrus-deploy-$$.sh"
        echo "  ssh -t $SSH_ALIAS \"export DEPLOY_SSH_ALIAS='$SSH_ALIAS' $PORT_ENV $DB_ENV_VARS $DOMAIN_ENV $EXTRA_ENV; bash '/tmp/mikrus-deploy-$$.sh'\""
    fi
    echo ""
    echo -e "${BLUE}[dry-run] Po instalacji:${NC}"
    if [ "$NEEDS_DOMAIN" = true ]; then
        echo "  configure_domain $APP_PORT $SSH_ALIAS"
    fi
    echo ""
    echo -e "${GREEN}[dry-run] Zakończono symulację.${NC}"
    exit 0
fi

# Upload script to server and execute
echo "🚀 Uruchamiam instalację na serwerze..."
echo ""

# =============================================================================
# BUILD FILE (dla GateFlow z prywatnego repo)
# =============================================================================

REMOTE_BUILD_FILE=""
if [ -n "$BUILD_FILE" ]; then
    # Rozwiń ~ do pełnej ścieżki
    BUILD_FILE="${BUILD_FILE/#\~/$HOME}"

    if [ ! -f "$BUILD_FILE" ]; then
        echo -e "${RED}❌ Plik nie istnieje: $BUILD_FILE${NC}"
        exit 1
    fi

    echo "📦 Przesyłam plik instalacyjny na serwer..."
    REMOTE_BUILD_FILE="/tmp/gateflow-build-$$.tar.gz"
    server_copy "$BUILD_FILE" "$REMOTE_BUILD_FILE"
    echo "   ✅ Plik przesłany"

    EXTRA_ENV="$EXTRA_ENV BUILD_FILE='$REMOTE_BUILD_FILE'"
fi

DEPLOY_SUCCESS=false
if is_on_server; then
    # Na serwerze: uruchom skrypt bezpośrednio (bez scp/cleanup)
    if (export DEPLOY_SSH_ALIAS="$SSH_ALIAS" SSH_ALIAS="$SSH_ALIAS" YES_MODE="$YES_MODE" $PORT_ENV $DB_ENV_VARS $DOMAIN_ENV $EXTRA_ENV; bash "$SCRIPT_PATH"); then
        DEPLOY_SUCCESS=true
    fi
    [ -n "$REMOTE_BUILD_FILE" ] && rm -f "$REMOTE_BUILD_FILE"
else
    REMOTE_SCRIPT="/tmp/mikrus-deploy-$$.sh"
    scp -q "$SCRIPT_PATH" "$SSH_ALIAS:$REMOTE_SCRIPT"

    # Cleanup remote build file after install
    CLEANUP_CMD=""
    if [ -n "$REMOTE_BUILD_FILE" ]; then
        CLEANUP_CMD="rm -f '$REMOTE_BUILD_FILE';"
    fi

    if ssh -t "$SSH_ALIAS" "export DEPLOY_SSH_ALIAS='$SSH_ALIAS' SSH_ALIAS='$SSH_ALIAS' YES_MODE='$YES_MODE' $PORT_ENV $DB_ENV_VARS $DOMAIN_ENV $EXTRA_ENV; bash '$REMOTE_SCRIPT'; EXIT_CODE=\$?; rm -f '$REMOTE_SCRIPT'; $CLEANUP_CMD exit \$EXIT_CODE"; then
        DEPLOY_SUCCESS=true
    fi
fi

if [ "$DEPLOY_SUCCESS" = true ]; then
    : # Sukces - kontynuuj do przygotowania bazy i konfiguracji domeny
else
    echo ""
    echo -e "${RED}❌ Instalacja NIEUDANA! Sprawdź błędy powyżej.${NC}"
    exit 1
fi

# =============================================================================
# KONFIGURACJA GATEFLOW PO INSTALACJI
# =============================================================================

if [ "$APP_NAME" = "gateflow" ]; then
    # 1. Migracje bazy danych
    echo ""
    echo "🗄️  Przygotowanie bazy danych..."

    if [ -f "$REPO_ROOT/local/setup-supabase-migrations.sh" ]; then
        SSH_ALIAS="$SSH_ALIAS" PROJECT_REF="$PROJECT_REF" SUPABASE_URL="$SUPABASE_URL" "$REPO_ROOT/local/setup-supabase-migrations.sh" || {
            echo -e "${YELLOW}⚠️  Nie udało się przygotować bazy - możesz uruchomić później:${NC}"
            echo "   SSH_ALIAS=$SSH_ALIAS ./local/setup-supabase-migrations.sh"
        }
    else
        echo -e "${YELLOW}⚠️  Brak skryptu przygotowania bazy${NC}"
    fi

    # 2. Skonsolidowana konfiguracja Supabase (Site URL, CAPTCHA, email templates)
    if [ -n "$SUPABASE_TOKEN" ] && [ -n "$PROJECT_REF" ]; then
        # Użyj funkcji z lib/gateflow-setup.sh
        # Przekazuje: domenę, secret turnstile, SSH alias (do pobrania szablonów email)
        configure_supabase_settings "$DOMAIN" "$GATEFLOW_TURNSTILE_SECRET" "$SSH_ALIAS" || {
            echo -e "${YELLOW}⚠️  Częściowa konfiguracja Supabase${NC}"
        }
    fi
    # Przypomnienia (Stripe, Turnstile, SMTP) będą wyświetlone na końcu
fi

# =============================================================================
# FAZA 3: KONFIGURACJA DOMENY (po uruchomieniu usługi!)
# =============================================================================

# Sprawdź czy install.sh zapisał port (dla dynamicznych portów jak Docker static sites)
INSTALLED_PORT=$(server_exec "cat /tmp/app_port 2>/dev/null; rm -f /tmp/app_port" 2>/dev/null)
if [ -n "$INSTALLED_PORT" ]; then
    APP_PORT="$INSTALLED_PORT"
fi

# Sprawdź czy install.sh zapisał STACK_DIR (dla multi-instance apps jak WordPress)
INSTALLED_STACK_DIR=$(server_exec "cat /tmp/app_stack_dir 2>/dev/null; rm -f /tmp/app_stack_dir" 2>/dev/null)
APP_STACK_DIR="${INSTALLED_STACK_DIR:-/opt/stacks/$APP_NAME}"

if [ "$NEEDS_DOMAIN" = true ] && [ "$DOMAIN_TYPE" != "local" ]; then
    echo ""
    ORIGINAL_DOMAIN="$DOMAIN"  # Zapamiętaj czy był "-" (automatyczny)
    if configure_domain "$APP_PORT" "$SSH_ALIAS"; then
        # Dla Cytrus z automatyczną domeną - zaktualizuj config prawdziwą domeną
        # Po configure_domain(), zmienna DOMAIN zawiera przydzieloną domenę
        if [ "$ORIGINAL_DOMAIN" = "-" ] && [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
            echo "🔄 Aktualizuję konfigurację z prawdziwą domeną: $DOMAIN"
            if [ "$REQUIRES_DOMAIN_UPFRONT" = true ]; then
                # Static sites - update Caddyfile
                server_exec "sudo sed -i 's|$CYTRUS_PLACEHOLDER|$DOMAIN|g' /etc/caddy/Caddyfile && sudo systemctl reload caddy" 2>/dev/null || true
            elif [ "$APP_NAME" != "gateflow" ]; then
                # Docker apps - update docker-compose (skip for standalone apps like GateFlow)
                server_exec "cd $APP_STACK_DIR && sed -i 's|$CYTRUS_PLACEHOLDER|$DOMAIN|g' docker-compose.yaml && docker compose up -d" 2>/dev/null || true
            fi
        fi

        # Dla GateFlow z Cytrus - zaktualizuj .env.local, Supabase i zapytaj o Turnstile
        if [ "$APP_NAME" = "gateflow" ] && [ "$ORIGINAL_DOMAIN" = "-" ] && [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
            # 1. Dodaj konfigurację domeny do .env.local (install.sh pominął dla DOMAIN="-")
            echo "📝 Aktualizuję .env.local z prawdziwą domeną..."
            server_exec "
                cd /opt/stacks/gateflow/admin-panel
                # Dodaj konfigurację domeny
                cat >> .env.local <<'DOMAIN_EOF'

# Site URLs (dodane po przydzieleniu domeny Cytrus)
SITE_URL=https://$DOMAIN
MAIN_DOMAIN=$DOMAIN
NEXT_PUBLIC_SITE_URL=https://$DOMAIN
NEXT_PUBLIC_BASE_URL=https://$DOMAIN
DISABLE_HSTS=true
DOMAIN_EOF
                # Skopiuj do standalone
                if [ -d '.next/standalone/admin-panel' ]; then
                    cp .env.local .next/standalone/admin-panel/.env.local
                fi
            " 2>/dev/null || true

            # 2. Restart PM2 żeby załadować nową konfigurację
            # Dla auto-cytrus początkowa instalacja używa PM2_NAME="gateflow"
            # Po poznaniu domeny możemy zachować tę nazwę (single instance)
            echo "🔄 Restartuję GateFlow..."
            server_exec "
                export PATH=\"\$HOME/.bun/bin:\$PATH\"
                cd /opt/stacks/gateflow/admin-panel/.next/standalone/admin-panel
                pm2 delete gateflow 2>/dev/null || true
                unset HOSTNAME
                set -a && source .env.local && set +a
                export PORT=\${PORT:-3333}
                export HOSTNAME=\${HOSTNAME:-::}
                pm2 start server.js --name gateflow --interpreter node
                pm2 save
            " 2>/dev/null || true

            # 3. Zaktualizuj Site URL w Supabase
            update_supabase_site_url "$DOMAIN" || true

            # Turnstile nie był oferowany wcześniej (nie znaliśmy domeny) - zapytaj teraz
            if [ "$TURNSTILE_OFFERED" != true ] && [ "$YES_MODE" != true ]; then
                echo ""
                echo "🔒 Konfiguracja Turnstile (CAPTCHA)"
                echo "   Domena: $DOMAIN"
                echo ""
                read -p "Skonfigurować Turnstile teraz? [T/n]: " SETUP_TURNSTILE_NOW
                if [[ ! "$SETUP_TURNSTILE_NOW" =~ ^[Nn]$ ]]; then
                    if [ -f "$REPO_ROOT/local/setup-turnstile.sh" ]; then
                        "$REPO_ROOT/local/setup-turnstile.sh" "$DOMAIN" "$SSH_ALIAS"
                        # Sprawdź czy klucze zostały zapisane
                        KEYS_FILE="$HOME/.config/cloudflare/turnstile_keys_$DOMAIN"
                        if [ -f "$KEYS_FILE" ]; then
                            source "$KEYS_FILE"
                            if [ -n "$CLOUDFLARE_TURNSTILE_SECRET_KEY" ]; then
                                GATEFLOW_TURNSTILE_SECRET="$CLOUDFLARE_TURNSTILE_SECRET_KEY"
                                echo -e "${GREEN}✅ Turnstile skonfigurowany!${NC}"
                            fi
                        fi
                    fi
                else
                    SETUP_TURNSTILE_LATER=true
                fi
            elif [ "$YES_MODE" = true ]; then
                # W trybie --yes - sprawdź zapisane klucze lub utwórz automatycznie
                KEYS_FILE="$HOME/.config/cloudflare/turnstile_keys_$DOMAIN"
                CF_TOKEN_FILE="$HOME/.config/cloudflare/turnstile_token"

                if [ -f "$KEYS_FILE" ]; then
                    # Mamy zapisane klucze dla tej domeny
                    source "$KEYS_FILE"
                    if [ -n "$CLOUDFLARE_TURNSTILE_SECRET_KEY" ]; then
                        GATEFLOW_TURNSTILE_SECRET="$CLOUDFLARE_TURNSTILE_SECRET_KEY"
                        configure_supabase_settings "$DOMAIN" "$GATEFLOW_TURNSTILE_SECRET" "" || true
                    fi
                elif [ -f "$CF_TOKEN_FILE" ]; then
                    # Mamy token Cloudflare - utwórz klucze automatycznie
                    echo ""
                    echo "🔒 Automatyczna konfiguracja Turnstile..."
                    if [ -f "$REPO_ROOT/local/setup-turnstile.sh" ]; then
                        "$REPO_ROOT/local/setup-turnstile.sh" "$DOMAIN" "$SSH_ALIAS"
                        # Sprawdź czy klucze zostały utworzone
                        if [ -f "$KEYS_FILE" ]; then
                            source "$KEYS_FILE"
                            if [ -n "$CLOUDFLARE_TURNSTILE_SECRET_KEY" ]; then
                                GATEFLOW_TURNSTILE_SECRET="$CLOUDFLARE_TURNSTILE_SECRET_KEY"
                                echo -e "${GREEN}✅ Turnstile skonfigurowany automatycznie${NC}"
                            fi
                        fi
                    fi
                else
                    SETUP_TURNSTILE_LATER=true
                fi
            fi
        fi
        # Poczekaj aż domena zacznie odpowiadać (timeout 90s)
        wait_for_domain 90
    else
        echo ""
        echo -e "${YELLOW}⚠️  Usługa działa, ale konfiguracja domeny nie powiodła się.${NC}"
        echo "   Możesz skonfigurować domenę ręcznie później."
    fi
fi

# Konfiguracja DOMAIN_PUBLIC (dla FileBrowser i podobnych)
if [ -n "$DOMAIN_PUBLIC" ]; then
    echo ""
    echo "🌍 Konfiguruję domenę publiczną: $DOMAIN_PUBLIC"

    # Sprawdź typ domeny
    is_cytrus_domain() {
        case "$1" in
            *.byst.re|*.bieda.it|*.toadres.pl|*.tojest.dev|*.mikr.us|*.srv24.pl|*.vxm.pl) return 0 ;;
            *) return 1 ;;
        esac
    }

    # Pobierz port dla public (domyślnie 8096)
    PUBLIC_PORT=$(server_exec "cat /tmp/app_public_port 2>/dev/null || echo 8096")

    if is_cytrus_domain "$DOMAIN_PUBLIC"; then
        # Cytrus: rejestruj domenę przez API
        echo "   🍊 Rejestruję w Cytrus na porcie $PUBLIC_PORT..."
        "$REPO_ROOT/local/cytrus-domain.sh" "$DOMAIN_PUBLIC" "$PUBLIC_PORT" "$SSH_ALIAS"
    else
        # Cloudflare: skonfiguruj DNS i Caddy file_server
        echo "   ☁️  Konfiguruję przez Cloudflare..."
        WEBROOT=$(server_exec "cat /tmp/domain_public_webroot 2>/dev/null || echo /var/www/public")
        # DNS może już istnieć - to OK, kontynuujemy z Caddy
        "$REPO_ROOT/local/dns-add.sh" "$DOMAIN_PUBLIC" "$SSH_ALIAS" || echo "   DNS już skonfigurowany lub błąd - kontynuuję"
        # Konfiguruj Caddy file_server
        if server_exec "command -v mikrus-expose &>/dev/null && mikrus-expose '$DOMAIN_PUBLIC' '$WEBROOT' static"; then
            echo -e "   ${GREEN}✅ Static hosting skonfigurowany: https://$DOMAIN_PUBLIC${NC}"
        else
            echo -e "   ${YELLOW}⚠️  Nie udało się skonfigurować Caddy dla $DOMAIN_PUBLIC${NC}"
        fi
        # Cleanup
        server_exec "rm -f /tmp/domain_public_webroot" 2>/dev/null
    fi
fi

# =============================================================================
# PODSUMOWANIE
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  🎉 GOTOWE!                                                    ║"
echo "╚════════════════════════════════════════════════════════════════╝"

if [ "$DOMAIN_TYPE" = "local" ]; then
    echo ""
    echo "📋 Dostęp przez tunel SSH:"
    echo -e "   ${BLUE}ssh -L $APP_PORT:localhost:$APP_PORT $SSH_ALIAS${NC}"
    echo "   Potem otwórz: http://localhost:$APP_PORT"
elif [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo ""
    echo -e "🌐 Aplikacja dostępna pod: ${BLUE}https://$DOMAIN${NC}"
fi

# Sugestia backupu dla aplikacji z bazą danych
if [ "$NEEDS_DB" = true ]; then
    echo ""
    echo -e "${YELLOW}💾 WAŻNE: Twoje dane są przechowywane w bazie danych!${NC}"
    echo "   Jeśli nie masz skonfigurowanego backupu bazy, rozważ:"
    echo ""
    echo "   Konfiguracja automatycznego backupu:"
    echo -e "      ${BLUE}ssh $SSH_ALIAS \"bash /opt/mikrus-toolbox/system/setup-db-backup.sh\"${NC}"
    echo ""
fi

# Przypomnienia post-instalacyjne dla GateFlow
if [ "$APP_NAME" = "gateflow" ]; then
    # Określ czy Turnstile jest skonfigurowany
    TURNSTILE_CONFIGURED=false
    [ -n "$GATEFLOW_TURNSTILE_SECRET" ] && TURNSTILE_CONFIGURED=true

    echo ""
    echo -e "${YELLOW}📋 Następne kroki:${NC}"
    gateflow_show_post_install_reminders "$DOMAIN" "$SSH_ALIAS" "$GATEFLOW_STRIPE_CONFIGURED" "$TURNSTILE_CONFIGURED"
fi

# =============================================================================
# KONDYCJA SERWERA (po instalacji)
# =============================================================================

POST_RESOURCES=$(server_exec_timeout 10 "free -m | awk '/^Mem:/ {print \$2, \$7}'; df -m / | awk 'NR==2 {print \$2, \$4}'" 2>/dev/null)
POST_RAM_LINE=$(echo "$POST_RESOURCES" | sed -n '1p')
POST_DISK_LINE=$(echo "$POST_RESOURCES" | sed -n '2p')

POST_RAM_TOTAL=$(echo "$POST_RAM_LINE" | awk '{print $1}')
POST_RAM_AVAIL=$(echo "$POST_RAM_LINE" | awk '{print $2}')
POST_DISK_TOTAL=$(echo "$POST_DISK_LINE" | awk '{print $1}')
POST_DISK_AVAIL=$(echo "$POST_DISK_LINE" | awk '{print $2}')

if [ -n "$POST_RAM_TOTAL" ] && [ "$POST_RAM_TOTAL" -gt 0 ] 2>/dev/null && \
   [ -n "$POST_DISK_TOTAL" ] && [ "$POST_DISK_TOTAL" -gt 0 ] 2>/dev/null; then

    RAM_USED_PCT=$(( (POST_RAM_TOTAL - POST_RAM_AVAIL) * 100 / POST_RAM_TOTAL ))
    DISK_USED_PCT=$(( (POST_DISK_TOTAL - POST_DISK_AVAIL) * 100 / POST_DISK_TOTAL ))
    DISK_AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $POST_DISK_AVAIL / 1024}")
    DISK_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $POST_DISK_TOTAL / 1024}")

    # RAM label
    if [ "$RAM_USED_PCT" -gt 80 ]; then
        RAM_LABEL="${RED}KRYTYCZNIE${NC}"
        RAM_LEVEL=2
    elif [ "$RAM_USED_PCT" -gt 60 ]; then
        RAM_LABEL="${YELLOW}CIASNO${NC}"
        RAM_LEVEL=1
    else
        RAM_LABEL="${GREEN}OK${NC}"
        RAM_LEVEL=0
    fi

    # Disk label
    if [ "$DISK_USED_PCT" -gt 85 ]; then
        DISK_LABEL="${RED}KRYTYCZNIE${NC}"
        DISK_LEVEL=2
    elif [ "$DISK_USED_PCT" -gt 60 ]; then
        DISK_LABEL="${YELLOW}CIASNO${NC}"
        DISK_LEVEL=1
    else
        DISK_LABEL="${GREEN}OK${NC}"
        DISK_LEVEL=0
    fi

    # Worst level
    HEALTH_LEVEL=$RAM_LEVEL
    [ "$DISK_LEVEL" -gt "$HEALTH_LEVEL" ] && HEALTH_LEVEL=$DISK_LEVEL

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  📊 Kondycja serwera po instalacji                             ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo -e "   RAM:  ${POST_RAM_AVAIL}MB / ${POST_RAM_TOTAL}MB wolne (${RAM_USED_PCT}% zajęte) — $RAM_LABEL"
    echo -e "   Dysk: ${DISK_AVAIL_GB}GB / ${DISK_TOTAL_GB}GB wolne (${DISK_USED_PCT}% zajęte) — $DISK_LABEL"
    echo ""

    if [ "$HEALTH_LEVEL" -eq 0 ]; then
        echo -e "   ${GREEN}✅ Serwer w dobrej kondycji. Możesz spokojnie dodawać kolejne usługi.${NC}"
    elif [ "$HEALTH_LEVEL" -eq 1 ]; then
        echo -e "   ${YELLOW}⚠️  Robi się ciasno. Rozważ upgrade przed dodawaniem ciężkich usług.${NC}"
    else
        echo -e "   ${RED}❌ Serwer mocno obciążony! Rozważ upgrade lub usunięcie nieużywanych usług.${NC}"
    fi

    # Sugestia upgrade
    if [ "$HEALTH_LEVEL" -ge 1 ]; then
        UPGRADE=""
        if [ "$POST_RAM_TOTAL" -le 1024 ]; then
            UPGRADE="Mikrus 3.0 (2GB RAM, 130 PLN/rok)"
        elif [ "$POST_RAM_TOTAL" -le 2048 ]; then
            UPGRADE="Mikrus 3.5 (4GB RAM, 197 PLN/rok)"
        elif [ "$POST_RAM_TOTAL" -le 4096 ]; then
            UPGRADE="Mikrus 4.1 (8GB RAM, 395 PLN/rok)"
        elif [ "$POST_RAM_TOTAL" -le 8192 ]; then
            UPGRADE="Mikrus 4.2 (16GB RAM, 790 PLN/rok)"
        fi
        if [ -n "$UPGRADE" ]; then
            echo -e "   ${YELLOW}📦 Sugerowany upgrade: $UPGRADE${NC}"
            echo -e "   ${YELLOW}   https://mikr.us/?r=pavvel#plans${NC}"
        fi
    fi
fi

echo ""
