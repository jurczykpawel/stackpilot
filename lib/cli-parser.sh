#!/bin/bash

# Mikrus Toolbox - CLI Parser
# Uniwersalny parser argumentów dla wszystkich skryptów.
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   source "$REPO_ROOT/lib/cli-parser.sh"
#   parse_args "$@"
#
# Priorytet wartości:
#   1. Flagi CLI (--db-host=...)     ← najwyższy
#   2. Zmienne środowiskowe (DB_HOST=...)
#   3. Config file (~/.config/mikrus/defaults.sh)
#   4. Pytania interaktywne          ← fallback
#
# Dostępne po parse_args():
#   $SSH_ALIAS, $DB_SOURCE, $DB_HOST, $DB_PORT, $DB_NAME, $DB_SCHEMA,
#   $DB_USER, $DB_PASS, $DOMAIN, $DOMAIN_TYPE, $YES_MODE, $DRY_RUN,
#   ${POSITIONAL_ARGS[@]}

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# DETEKCJA ŚRODOWISKA (Git Bash / WSL / etc.)
# =============================================================================

detect_environment() {
    # Wykryj Git Bash / MINGW / MSYS
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "mingw"* ]] || [[ -n "$MSYSTEM" ]]; then
        IS_GITBASH=true

        # Sprawdź czy to MinTTY (problematyczny) czy Windows Terminal (OK)
        # MinTTY nie ustawia WT_SESSION, Windows Terminal tak
        if [[ -z "$WT_SESSION" ]] && [[ "$TERM_PROGRAM" != "vscode" ]]; then
            IS_MINTTY=true
        else
            IS_MINTTY=false
        fi
    else
        IS_GITBASH=false
        IS_MINTTY=false
    fi

    export IS_GITBASH IS_MINTTY
}

# Pokaż ostrzeżenie dla Git Bash + MinTTY (tylko raz, tylko interaktywnie)
warn_gitbash_mintty() {
    # Pomiń jeśli już pokazano, w trybie --yes, lub nie Git Bash
    if [[ "$GITBASH_WARNING_SHOWN" == "true" ]] || [[ "$YES_MODE" == "true" ]] || [[ "$IS_MINTTY" != "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠️  Wykryto Git Bash z MinTTY                                  ║${NC}"
    echo -e "${YELLOW}╠════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║  Tryb interaktywny może nie działać poprawnie.                 ║${NC}"
    echo -e "${YELLOW}║                                                                ║${NC}"
    echo -e "${YELLOW}║  Rozwiązania:                                                  ║${NC}"
    echo -e "${YELLOW}║  1. Użyj Windows Terminal zamiast MinTTY                       ║${NC}"
    echo -e "${YELLOW}║  2. Uruchom: winpty ./local/deploy.sh ...                      ║${NC}"
    echo -e "${YELLOW}║  3. Użyj trybu automatycznego: --yes                           ║${NC}"
    echo -e "${YELLOW}║  4. Zainstaluj WSL2 (najlepsze rozwiązanie)                    ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    export GITBASH_WARNING_SHOWN=true
}

# Uruchom detekcję od razu
detect_environment

# Globalne zmienne (nie resetuj jeśli już ustawione przez env)
export SSH_ALIAS="${SSH_ALIAS:-}"
export DB_SOURCE="${DB_SOURCE:-}"
export DB_HOST="${DB_HOST:-}"
export DB_PORT="${DB_PORT:-}"
export DB_NAME="${DB_NAME:-}"
export DB_SCHEMA="${DB_SCHEMA:-}"
export DB_USER="${DB_USER:-}"
export DB_PASS="${DB_PASS:-}"
export DOMAIN="${DOMAIN:-}"
export DOMAIN_TYPE="${DOMAIN_TYPE:-}"
export SUPABASE_PROJECT="${SUPABASE_PROJECT:-}"
export INSTANCE="${INSTANCE:-}"
export APP_PORT="${APP_PORT:-}"
export YES_MODE="${YES_MODE:-false}"
export DRY_RUN="${DRY_RUN:-false}"
export UPDATE_MODE="${UPDATE_MODE:-false}"
export RESTART_ONLY="${RESTART_ONLY:-false}"
export POSITIONAL_ARGS=()

# Ścieżka do config file
CONFIG_FILE="$HOME/.config/mikrus/defaults.sh"

# =============================================================================
# ŁADOWANIE KONFIGURACJI
# =============================================================================

load_defaults() {
    # Załaduj config file jeśli istnieje
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    # Ustaw domyślne wartości z config lub hardcoded defaults
    SSH_ALIAS="${SSH_ALIAS:-${DEFAULT_SSH:-mikrus}}"
    DB_PORT="${DB_PORT:-${DEFAULT_DB_PORT:-5432}}"
    DB_SCHEMA="${DB_SCHEMA:-${DEFAULT_DB_SCHEMA:-public}}"
    DOMAIN_TYPE="${DOMAIN_TYPE:-${DEFAULT_DOMAIN_TYPE:-}}"
}

# =============================================================================
# PARSER ARGUMENTÓW
# =============================================================================

parse_args() {
    POSITIONAL_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            # SSH
            --ssh=*) SSH_ALIAS="${1#*=}" ;;
            --ssh) SSH_ALIAS="$2"; shift ;;

            # Database
            --db-source=*) DB_SOURCE="${1#*=}" ;;
            --db-source) DB_SOURCE="$2"; shift ;;
            --db-host=*) DB_HOST="${1#*=}" ;;
            --db-host) DB_HOST="$2"; shift ;;
            --db-port=*) DB_PORT="${1#*=}" ;;
            --db-port) DB_PORT="$2"; shift ;;
            --db-name=*) DB_NAME="${1#*=}" ;;
            --db-name) DB_NAME="$2"; shift ;;
            --db-schema=*) DB_SCHEMA="${1#*=}" ;;
            --db-schema) DB_SCHEMA="$2"; shift ;;
            --db-user=*) DB_USER="${1#*=}" ;;
            --db-user) DB_USER="$2"; shift ;;
            --db-pass=*) DB_PASS="${1#*=}" ;;
            --db-pass) DB_PASS="$2"; shift ;;

            # Domain
            --domain=*) DOMAIN="${1#*=}" ;;
            --domain) DOMAIN="$2"; shift ;;
            --domain-type=*) DOMAIN_TYPE="${1#*=}" ;;
            --domain-type) DOMAIN_TYPE="$2"; shift ;;

            # Supabase (for GateFlow)
            --supabase-project=*) SUPABASE_PROJECT="${1#*=}" ;;
            --supabase-project) SUPABASE_PROJECT="$2"; shift ;;

            # Multi-instance
            --instance=*) INSTANCE="${1#*=}" ;;
            --instance) INSTANCE="$2"; shift ;;
            --port=*) APP_PORT="${1#*=}" ;;
            --port) APP_PORT="$2"; shift ;;

            # Modes
            --yes|-y) YES_MODE=true ;;
            --dry-run) DRY_RUN=true ;;
            --update) UPDATE_MODE=true ;;
            --restart) RESTART_ONLY=true ;;
            --build-file=*) BUILD_FILE="${1#*=}" ;;
            --build-file) BUILD_FILE="$2"; shift ;;
            --help|-h) show_help; exit 0 ;;

            # Unknown options
            --*)
                echo -e "${RED}Nieznana opcja: $1${NC}" >&2
                echo "Użyj --help aby zobaczyć dostępne opcje." >&2
                exit 1
                ;;

            # Positional arguments
            *)
                POSITIONAL_ARGS+=("$1")
                ;;
        esac
        shift
    done

    # Eksportuj zmienne
    export SSH_ALIAS DB_SOURCE DB_HOST DB_PORT DB_NAME DB_SCHEMA DB_USER DB_PASS
    export DOMAIN DOMAIN_TYPE SUPABASE_PROJECT INSTANCE APP_PORT
    export YES_MODE DRY_RUN UPDATE_MODE RESTART_ONLY BUILD_FILE
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    local SCRIPT_NAME="${0##*/}"
    cat <<EOF
Mikrus Toolbox - $SCRIPT_NAME

Użycie:
  $SCRIPT_NAME APP [opcje]

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
  --domain=DOMAIN      Domena aplikacji (np. app.example.com)
  --domain-type=TYPE   Typ: cytrus, cloudflare, local

Opcje GateFlow:
  --supabase-project=REF  Project ref Supabase (pomija wybór interaktywny)
  --instance=NAME         Nazwa instancji (dla multi-instance, np. --instance=shop)
  --port=PORT             Port aplikacji (domyślnie: auto-increment od 3333)

Tryby:
  --yes, -y            Pomiń wszystkie potwierdzenia (wymaga pełnych parametrów)
  --dry-run            Pokaż co się wykona bez wykonania
  --update             Aktualizuj istniejącą aplikację
  --restart            Restart bez aktualizacji (np. po zmianie .env) - używany z --update
  --help, -h           Pokaż tę pomoc

Przykłady:
  # Interaktywny (pytania o brakujące dane)
  $SCRIPT_NAME n8n --ssh=mikrus

  # Pełna automatyzacja
  $SCRIPT_NAME n8n --ssh=mikrus --db-source=shared --domain=n8n.example.com --yes

  # Custom database
  $SCRIPT_NAME n8n --ssh=mikrus --db-source=custom --db-host=psql.example.com \\
    --db-name=n8n --db-user=myuser --db-pass=secret --domain=n8n.example.com --yes

Config file:
  ~/.config/mikrus/defaults.sh
  Przykład:
    export DEFAULT_SSH="mikrus"
    export DEFAULT_DB_PORT="5432"
    export DEFAULT_DOMAIN_TYPE="cytrus"

EOF
}

# =============================================================================
# HELPER: PYTAJ TYLKO GDY BRAK WARTOŚCI
# =============================================================================

# ask_if_empty VAR_NAME "Prompt" [default] [secret]
# Przykład: ask_if_empty DB_HOST "Host bazy danych"
# Przykład: ask_if_empty DB_PORT "Port" "5432"
# Przykład: ask_if_empty DB_PASS "Hasło" "" true
ask_if_empty() {
    local VAR_NAME="$1"
    local PROMPT="$2"
    local DEFAULT="${3:-}"
    local SECRET="${4:-false}"

    # Sprawdź czy zmienna już ma wartość
    if [ -n "${!VAR_NAME}" ]; then
        return 0
    fi

    # Tryb --yes bez wartości = błąd
    if [ "$YES_MODE" = true ]; then
        echo -e "${RED}Błąd: --${VAR_NAME,,} jest wymagane w trybie --yes${NC}" >&2
        exit 1
    fi

    # Dry-run - nie pytaj
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[dry-run] Brak wartości dla $VAR_NAME${NC}"
        return 0
    fi

    # Pytaj interaktywnie
    local VALUE
    if [ "$SECRET" = true ]; then
        read -sp "$PROMPT: " VALUE
        echo
    elif [ -n "$DEFAULT" ]; then
        read -p "$PROMPT [$DEFAULT]: " VALUE
        VALUE="${VALUE:-$DEFAULT}"
    else
        read -p "$PROMPT: " VALUE
    fi

    # Ustaw zmienną (printf -v zamiast eval — bezpieczne dla wartości z apostrof)
    printf -v "$VAR_NAME" '%s' "$VALUE"
    export "$VAR_NAME"
}

# =============================================================================
# HELPER: WYBÓR Z OPCJI
# =============================================================================

# ask_choice VAR_NAME "Prompt" "opt1|opt2|opt3" [default_index]
# Przykład: ask_choice DB_SOURCE "Wybierz źródło bazy" "shared|custom" 1
ask_choice() {
    local VAR_NAME="$1"
    local PROMPT="$2"
    local OPTIONS="$3"
    local DEFAULT_INDEX="${4:-}"

    # Sprawdź czy zmienna już ma wartość
    if [ -n "${!VAR_NAME}" ]; then
        return 0
    fi

    # Tryb --yes bez wartości = błąd
    if [ "$YES_MODE" = true ]; then
        echo -e "${RED}Błąd: --${VAR_NAME,,} jest wymagane w trybie --yes${NC}" >&2
        exit 1
    fi

    # Dry-run - nie pytaj
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[dry-run] Brak wartości dla $VAR_NAME${NC}"
        return 0
    fi

    # Parsuj opcje
    IFS='|' read -ra OPTS <<< "$OPTIONS"

    echo ""
    echo "$PROMPT"
    echo ""
    local i=1
    for opt in "${OPTS[@]}"; do
        local marker=""
        if [ "$i" = "$DEFAULT_INDEX" ]; then
            marker=" (domyślnie)"
        fi
        echo "  $i) $opt$marker"
        ((i++))
    done
    echo ""

    local CHOICE
    read -p "Wybierz [1-${#OPTS[@]}]: " CHOICE

    # Użyj default jeśli puste
    if [ -z "$CHOICE" ] && [ -n "$DEFAULT_INDEX" ]; then
        CHOICE="$DEFAULT_INDEX"
    fi

    # Walidacja
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#OPTS[@]}" ]; then
        echo -e "${RED}Nieprawidłowy wybór${NC}" >&2
        return 1
    fi

    # Ustaw zmienną (printf -v zamiast eval — bezpieczne dla wartości ze znakami specjalnymi)
    local VALUE="${OPTS[$((CHOICE-1))]}"
    printf -v "$VAR_NAME" '%s' "$VALUE"
    export "$VAR_NAME"
}

# =============================================================================
# HELPER: POTWIERDZENIE
# =============================================================================

# confirm "Czy kontynuować?"
# Zwraca 0 (true) lub 1 (false)
confirm() {
    local MESSAGE="$1"

    # Tryb --yes = zawsze tak
    if [ "$YES_MODE" = true ]; then
        return 0
    fi

    # Dry-run = zawsze tak (ale nic nie robimy)
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[dry-run] Auto-potwierdzenie: $MESSAGE${NC}"
        return 0
    fi

    read -p "$MESSAGE (t/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[TtYy]$ ]]
}

# =============================================================================
# HELPER: DRY-RUN OUTPUT
# =============================================================================

# dry_run_cmd "opis" "komenda"
# W trybie dry-run wyświetla komendę, w normalnym wykonuje
dry_run_cmd() {
    local DESC="$1"
    local CMD="$2"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[dry-run] $DESC:${NC}"
        echo "  $CMD"
        return 0
    fi

    # Bezpośrednie wywołanie (bez eval — unikamy command injection)
    bash -c "$CMD"
}

# =============================================================================
# EKSPORT FUNKCJI
# =============================================================================

export -f detect_environment
export -f warn_gitbash_mintty
export -f load_defaults
export -f parse_args
export -f show_help
export -f ask_if_empty
export -f ask_choice
export -f confirm
export -f dry_run_cmd
