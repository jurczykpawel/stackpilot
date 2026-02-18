#!/bin/bash

# Mikrus Toolbox - Resource Check
# Sprawdza zasoby serwera przed instalacją.
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   source /opt/mikrus-toolbox/lib/resource-check.sh
#   check_resources 512 500  # wymagane: 512MB RAM, 500MB dysku
#
# Zwraca:
#   0 = OK, zasoby wystarczające
#   1 = WARN, mało zasobów ale można kontynuować
#   2 = FAIL, za mało zasobów

# Kolory
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# Pobierz dostępne zasoby
get_available_ram_mb() {
    free -m | awk '/^Mem:/ {print $7}'
}

get_available_disk_mb() {
    df -m / | awk 'NR==2 {print $4}'
}

get_total_ram_mb() {
    free -m | awk '/^Mem:/ {print $2}'
}

# Sprawdź zasoby
# check_resources REQUIRED_RAM_MB REQUIRED_DISK_MB [APP_NAME]
check_resources() {
    local REQUIRED_RAM="${1:-256}"
    local REQUIRED_DISK="${2:-200}"
    local APP_NAME="${3:-aplikacja}"

    local AVAILABLE_RAM=$(get_available_ram_mb)
    local AVAILABLE_DISK=$(get_available_disk_mb)
    local TOTAL_RAM=$(get_total_ram_mb)

    local STATUS=0

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  📊 Sprawdzanie zasobów serwera                               ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    # RAM check
    echo -n "   RAM: ${AVAILABLE_RAM}MB dostępne"
    if [ "$AVAILABLE_RAM" -lt "$REQUIRED_RAM" ]; then
        echo -e " ${RED}✗ (wymagane: ${REQUIRED_RAM}MB)${NC}"
        STATUS=2
    elif [ "$AVAILABLE_RAM" -lt $((REQUIRED_RAM * 2)) ]; then
        echo -e " ${YELLOW}⚠ (zalecane: ${REQUIRED_RAM}MB+)${NC}"
        [ "$STATUS" -lt 1 ] && STATUS=1
    else
        echo -e " ${GREEN}✓${NC}"
    fi

    # Disk check
    echo -n "   Dysk: ${AVAILABLE_DISK}MB wolne"
    if [ "$AVAILABLE_DISK" -lt "$REQUIRED_DISK" ]; then
        echo -e " ${RED}✗ (wymagane: ${REQUIRED_DISK}MB)${NC}"
        STATUS=2
    elif [ "$AVAILABLE_DISK" -lt $((REQUIRED_DISK * 2)) ]; then
        echo -e " ${YELLOW}⚠ (zalecane: ${REQUIRED_DISK}MB+)${NC}"
        [ "$STATUS" -lt 1 ] && STATUS=1
    else
        echo -e " ${GREEN}✓${NC}"
    fi

    # Total RAM warning for heavy apps
    if [ "$REQUIRED_RAM" -ge 400 ] && [ "$TOTAL_RAM" -lt 2000 ]; then
        echo ""
        echo -e "   ${YELLOW}⚠ Ta aplikacja wymaga dużo RAM.${NC}"
        echo -e "   ${YELLOW}  Zalecany plan: Mikrus 3.0+ (2GB RAM)${NC}"
        [ "$STATUS" -lt 1 ] && STATUS=1
    fi

    echo ""

    # Summary
    case $STATUS in
        0)
            echo -e "   ${GREEN}✅ Zasoby wystarczające do instalacji $APP_NAME${NC}"
            ;;
        1)
            echo -e "   ${YELLOW}⚠️  Mało zasobów - instalacja możliwa, ale może być ciasno${NC}"
            ;;
        2)
            echo -e "   ${RED}❌ Za mało zasobów! Instalacja $APP_NAME może zawiesić serwer.${NC}"
            echo -e "   ${RED}   Zwolnij miejsce lub upgraduj plan Mikrusa.${NC}"
            ;;
    esac

    echo ""
    return $STATUS
}

# Szybkie sprawdzenie (bez fancy output)
quick_resource_check() {
    local REQUIRED_RAM="${1:-256}"
    local REQUIRED_DISK="${2:-200}"

    local AVAILABLE_RAM=$(get_available_ram_mb)
    local AVAILABLE_DISK=$(get_available_disk_mb)

    if [ "$AVAILABLE_RAM" -lt "$REQUIRED_RAM" ] || [ "$AVAILABLE_DISK" -lt "$REQUIRED_DISK" ]; then
        return 1
    fi
    return 0
}

# Eksport funkcji
export -f get_available_ram_mb
export -f get_available_disk_mb
export -f get_total_ram_mb
export -f check_resources
export -f quick_resource_check
