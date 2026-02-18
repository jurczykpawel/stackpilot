#!/bin/bash

# Mikrus Toolbox - Health Check Helper
# Sprawdza czy kontener wystartował i aplikacja odpowiada.
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   source "$(dirname "$0")/../../lib/health-check.sh"
#   wait_for_healthy "$APP_NAME" "$PORT" [timeout_seconds]
#
# Funkcja zwraca:
#   0 - sukces (aplikacja działa)
#   1 - błąd (timeout lub app nie odpowiada)

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Sprawdza czy kontener działa i aplikacja odpowiada na HTTP
# Argumenty: APP_NAME PORT [TIMEOUT] [HEALTH_PATH]
# Używa $STACK_DIR z env jeśli ustawiony, inaczej /opt/stacks/$APP_NAME
wait_for_healthy() {
    local APP_NAME="$1"
    local PORT="$2"
    local TIMEOUT="${3:-30}"
    local HEALTH_PATH="${4:-/}"

    local STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
    local ELAPSED=0
    local INTERVAL=2

    echo ""
    echo "🔍 Sprawdzam czy $APP_NAME działa..."

    # 1. Sprawdź czy kontener jest running
    cd "$STACK_DIR" 2>/dev/null || {
        echo -e "${RED}❌ Nie znaleziono katalogu $STACK_DIR${NC}"
        return 1
    }

    # Czekaj na stan "running"
    while [ $ELAPSED -lt $TIMEOUT ]; do
        if sudo docker compose ps --format json 2>/dev/null | grep -q '"State":"running"'; then
            break
        fi
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
        echo -n "."
    done

    if ! sudo docker compose ps --format json 2>/dev/null | grep -q '"State":"running"'; then
        echo ""
        echo -e "${RED}❌ Kontener nie wystartował!${NC}"
        echo ""
        echo "📋 Logi:"
        sudo docker compose logs --tail 20
        return 1
    fi

    echo -e " kontener ${GREEN}running${NC}"

    # 2. Sprawdź czy aplikacja odpowiada na HTTP
    echo -n "   Czekam na odpowiedź HTTP"

    while [ $ELAPSED -lt $TIMEOUT ]; do
        # Sprawdź czy curl dostaje odpowiedź (jakąkolwiek, nawet 401/403)
        local HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:$PORT$HEALTH_PATH" 2>/dev/null)

        if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
            echo ""
            echo -e "   ${GREEN}✅ Aplikacja odpowiada (HTTP $HTTP_CODE)${NC}"
            return 0
        fi

        # Sprawdź czy kontener nadal działa (może crashować w pętli)
        if ! sudo docker compose ps --format json 2>/dev/null | grep -q '"State":"running"'; then
            echo ""
            echo -e "${RED}❌ Kontener przestał działać!${NC}"
            echo ""
            echo "📋 Logi:"
            sudo docker compose logs --tail 30
            return 1
        fi

        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
        echo -n "."
    done

    echo ""
    echo -e "${YELLOW}⚠️  Timeout - aplikacja nie odpowiada po ${TIMEOUT}s${NC}"
    echo ""
    echo "📋 Logi:"
    sudo docker compose logs --tail 30
    return 1
}

# Szybkie sprawdzenie - tylko czy kontener running (bez HTTP)
check_container_running() {
    local APP_NAME="$1"
    local STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"

    cd "$STACK_DIR" 2>/dev/null || return 1

    sleep 3
    if sudo docker compose ps --format json 2>/dev/null | grep -q '"State":"running"'; then
        echo -e "${GREEN}✅ Kontener $APP_NAME działa${NC}"
        return 0
    else
        echo -e "${RED}❌ Kontener $APP_NAME nie wystartował${NC}"
        sudo docker compose logs --tail 20
        return 1
    fi
}

# Eksportuj funkcje
export -f wait_for_healthy
export -f check_container_running
