#!/bin/bash

# StackPilot - GateFlow Update
# Aktualizuje GateFlow do najnowszej wersji
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   ./local/deploy.sh gateflow --ssh=mikrus --update
#   ./local/deploy.sh gateflow --ssh=mikrus --update --build-file=~/Downloads/gateflow-build.tar.gz
#   ./local/deploy.sh gateflow --ssh=mikrus --update --restart (restart bez aktualizacji)
#
# Zmienne środowiskowe:
#   BUILD_FILE - ścieżka do lokalnego pliku tar.gz (zamiast pobierania z GitHub)
#
# Flagi:
#   --restart - tylko restart aplikacji (np. po zmianie .env), bez pobierania nowej wersji
#
# Uwaga: Aktualizacja bazy danych jest obsługiwana przez deploy.sh (Supabase API)

set -e

GITHUB_REPO="jurczykpawel/gateflow"
RESTART_ONLY=false

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --restart)
            RESTART_ONLY=true
            shift
            ;;
    esac
done

# =============================================================================
# AUTO-DETEKCJA KATALOGU INSTALACJI
# =============================================================================
# Nowa lokalizacja: /opt/stacks/gateflow* (backup-friendly)
# Stara lokalizacja: /root/gateflow* (dla kompatybilności)

find_gateflow_dir() {
    local NAME="$1"
    # Sprawdź nową lokalizację
    if [ -d "/opt/stacks/gateflow-${NAME}" ]; then
        echo "/opt/stacks/gateflow-${NAME}"
    elif [ -d "/root/gateflow-${NAME}" ]; then
        echo "/root/gateflow-${NAME}"
    elif [ -d "/opt/stacks/gateflow" ]; then
        echo "/opt/stacks/gateflow"
    elif [ -d "/root/gateflow" ]; then
        echo "/root/gateflow"
    fi
}

if [ -n "$INSTANCE" ]; then
    INSTALL_DIR=$(find_gateflow_dir "$INSTANCE")
    PM2_NAME="gateflow-${INSTANCE}"
elif ls -d /opt/stacks/gateflow-* &>/dev/null 2>&1; then
    INSTALL_DIR=$(ls -d /opt/stacks/gateflow-* 2>/dev/null | head -1)
    PM2_NAME="gateflow-${INSTALL_DIR##*-}"
elif ls -d /root/gateflow-* &>/dev/null 2>&1; then
    INSTALL_DIR=$(ls -d /root/gateflow-* 2>/dev/null | head -1)
    PM2_NAME="gateflow-${INSTALL_DIR##*-}"
elif [ -d "/opt/stacks/gateflow" ]; then
    INSTALL_DIR="/opt/stacks/gateflow"
    PM2_NAME="$PM2_NAME"
else
    INSTALL_DIR="/root/gateflow"
    PM2_NAME="$PM2_NAME"
fi

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
if [ "$RESTART_ONLY" = true ]; then
    echo -e "${BLUE}🔄 GateFlow Restart${NC}"
else
    echo -e "${BLUE}🔄 GateFlow Update${NC}"
fi
echo ""

# =============================================================================
# 1. SPRAWDŹ CZY GATEFLOW JEST ZAINSTALOWANY
# =============================================================================

if [ ! -d "$INSTALL_DIR/admin-panel" ]; then
    echo -e "${RED}❌ GateFlow nie jest zainstalowany${NC}"
    echo "   Użyj deploy.sh do pierwszej instalacji."
    exit 1
fi

ENV_FILE="$INSTALL_DIR/admin-panel/.env.local"
STANDALONE_DIR="$INSTALL_DIR/admin-panel/.next/standalone/admin-panel"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Brak pliku .env.local${NC}"
    exit 1
fi

echo "✅ GateFlow znaleziony w $INSTALL_DIR"

# Pobierz aktualną wersję (jeśli dostępna)
CURRENT_VERSION="nieznana"
if [ -f "$INSTALL_DIR/admin-panel/version.txt" ]; then
    CURRENT_VERSION=$(cat "$INSTALL_DIR/admin-panel/version.txt")
fi
echo "   Aktualna wersja: $CURRENT_VERSION"

# =============================================================================
# 2. POBIERZ NOWĄ WERSJĘ (pominąć w trybie restart)
# =============================================================================

if [ "$RESTART_ONLY" = false ]; then
    echo ""

    # Backup starej konfiguracji
    cp "$ENV_FILE" "$INSTALL_DIR/.env.local.backup"
    echo "   Backup .env.local utworzony"

    # Pobierz do tymczasowego folderu
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    cd "$TEMP_DIR"

    # Sprawdź czy mamy lokalny plik
    if [ -n "$BUILD_FILE" ] && [ -f "$BUILD_FILE" ]; then
        echo "📦 Używam lokalnego pliku: $BUILD_FILE"
        if ! tar -xzf "$BUILD_FILE"; then
            echo -e "${RED}❌ Nie udało się rozpakować pliku${NC}"
            exit 1
        fi
    else
        echo "📥 Pobieram z GitHub..."
        RELEASE_URL="https://github.com/$GITHUB_REPO/releases/latest/download/gateflow-build.tar.gz"
        if ! curl -fsSL "$RELEASE_URL" | tar -xz; then
            echo -e "${RED}❌ Nie udało się pobrać nowej wersji${NC}"
            echo ""
            echo "Jeśli repo jest prywatne, użyj --build-file:"
            echo "   ./local/deploy.sh gateflow --ssh=mikrus --update --build-file=~/Downloads/gateflow-build.tar.gz"
            exit 1
        fi
    fi

    if [ ! -d ".next/standalone" ]; then
        echo -e "${RED}❌ Nieprawidłowa struktura archiwum${NC}"
        exit 1
    fi

    # Sprawdź nową wersję
    NEW_VERSION="nieznana"
    if [ -f "version.txt" ]; then
        NEW_VERSION=$(cat version.txt)
    fi
    echo "   Nowa wersja: $NEW_VERSION"

    if [ "$CURRENT_VERSION" = "$NEW_VERSION" ] && [ "$CURRENT_VERSION" != "nieznana" ]; then
        echo -e "${YELLOW}⚠️  Masz już najnowszą wersję ($CURRENT_VERSION)${NC}"
        read -p "Kontynuować mimo to? [t/N]: " CONTINUE
        if [[ ! "$CONTINUE" =~ ^[TtYy]$ ]]; then
            echo "Anulowano."
            exit 0
        fi
    fi
else
    echo ""
    echo "📋 Tryb restart - pominięto pobieranie nowej wersji"
fi

# =============================================================================
# 3. ZATRZYMAJ APLIKACJĘ
# =============================================================================

echo ""
echo "⏹️  Zatrzymuję GateFlow..."

export PATH="$HOME/.bun/bin:$PATH"
pm2 stop $PM2_NAME 2>/dev/null || true

# =============================================================================
# 4. ZAMIEŃ PLIKI (pominąć w trybie restart)
# =============================================================================

if [ "$RESTART_ONLY" = false ]; then
    echo ""
    echo "📦 Aktualizuję pliki..."

    # Usuń stare pliki (zachowaj .env.local backup)
    rm -rf "$INSTALL_DIR/admin-panel/.next"
    rm -rf "$INSTALL_DIR/admin-panel/public"

    # Skopiuj nowe
    cp -r "$TEMP_DIR/.next" "$INSTALL_DIR/admin-panel/"
    cp -r "$TEMP_DIR/public" "$INSTALL_DIR/admin-panel/" 2>/dev/null || true
    cp "$TEMP_DIR/version.txt" "$INSTALL_DIR/admin-panel/" 2>/dev/null || true

    # Przywróć .env.local
    cp "$INSTALL_DIR/.env.local.backup" "$ENV_FILE"

    echo -e "${GREEN}✅ Pliki zaktualizowane${NC}"
else
    echo ""
    echo "📋 Tryb restart - pominięto aktualizację plików"
fi

# Skopiuj do standalone (zawsze, zarówno w update jak i restart)
STANDALONE_DIR="$INSTALL_DIR/admin-panel/.next/standalone/admin-panel"
if [ -d "$STANDALONE_DIR" ]; then
    echo "   Aktualizuję konfigurację w standalone..."
    cp "$ENV_FILE" "$STANDALONE_DIR/.env.local"
    if [ "$RESTART_ONLY" = false ]; then
        cp -r "$INSTALL_DIR/admin-panel/.next/static" "$STANDALONE_DIR/.next/" 2>/dev/null || true
        cp -r "$INSTALL_DIR/admin-panel/public" "$STANDALONE_DIR/" 2>/dev/null || true
    fi
fi

# Migracje są uruchamiane przez deploy.sh przez Supabase API (nie tutaj)

# =============================================================================
# 5. URUCHOM APLIKACJĘ
# =============================================================================

echo ""
echo "🚀 Uruchamiam GateFlow..."

cd "$STANDALONE_DIR"

# Załaduj zmienne i uruchom
# Wyczyść systemowy HOSTNAME (to nazwa maszyny, nie adres nasłuchiwania)
# Bez tego ${HOSTNAME:-::} nigdy nie fallbackuje do :: bo system zawsze ustawia HOSTNAME
unset HOSTNAME
set -a
source .env.local
set +a
export PORT="${PORT:-3333}"
# :: słucha na IPv4 i IPv6 (wymagane dla Cytrus który łączy się przez IPv6)
export HOSTNAME="${HOSTNAME:-::}"

pm2 delete $PM2_NAME 2>/dev/null || true
# WAŻNE: użyj --interpreter node, NIE "node server.js" w cudzysłowach
pm2 start server.js --name $PM2_NAME --interpreter node
pm2 save

# Poczekaj i sprawdź
sleep 3

if pm2 list | grep -q "$PM2_NAME.*online"; then
    echo -e "${GREEN}✅ GateFlow działa!${NC}"
else
    echo -e "${RED}❌ Problem z uruchomieniem. Logi:${NC}"
    pm2 logs $PM2_NAME --lines 20
    exit 1
fi

# =============================================================================
# 6. PODSUMOWANIE
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
if [ "$RESTART_ONLY" = true ]; then
    echo -e "${GREEN}✅ GateFlow zrestartowany!${NC}"
else
    echo -e "${GREEN}✅ GateFlow zaktualizowany!${NC}"
fi
echo "════════════════════════════════════════════════════════════════"
echo ""
if [ "$RESTART_ONLY" = false ]; then
    echo "   Poprzednia wersja: $CURRENT_VERSION"
    echo "   Nowa wersja: $NEW_VERSION"
    echo ""
fi
echo "📋 Przydatne komendy:"
echo "   pm2 logs $PM2_NAME - logi"
echo "   pm2 restart $PM2_NAME - restart"
echo "   ./update.sh --restart - restart bez aktualizacji (np. po zmianie .env)"
echo ""
