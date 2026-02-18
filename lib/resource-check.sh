#!/bin/bash

# StackPilot - Resource Check
# Checks server resources before installation.
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   source /opt/stackpilot/lib/resource-check.sh
#   check_resources 512 500  # required: 512MB RAM, 500MB disk
#
# Returns:
#   0 = OK, resources sufficient
#   1 = WARN, low resources but can continue
#   2 = FAIL, not enough resources

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# Get available resources
get_available_ram_mb() {
    free -m | awk '/^Mem:/ {print $7}'
}

get_available_disk_mb() {
    df -m / | awk 'NR==2 {print $4}'
}

get_total_ram_mb() {
    free -m | awk '/^Mem:/ {print $2}'
}

# Check resources
# check_resources REQUIRED_RAM_MB REQUIRED_DISK_MB [APP_NAME]
check_resources() {
    local REQUIRED_RAM="${1:-256}"
    local REQUIRED_DISK="${2:-200}"
    local APP_NAME="${3:-application}"

    local AVAILABLE_RAM=$(get_available_ram_mb)
    local AVAILABLE_DISK=$(get_available_disk_mb)
    local TOTAL_RAM=$(get_total_ram_mb)

    local STATUS=0

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  📊 Checking server resources                                  ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    # RAM check
    echo -n "   RAM: ${AVAILABLE_RAM}MB available"
    if [ "$AVAILABLE_RAM" -lt "$REQUIRED_RAM" ]; then
        echo -e " ${RED}✗ (required: ${REQUIRED_RAM}MB)${NC}"
        STATUS=2
    elif [ "$AVAILABLE_RAM" -lt $((REQUIRED_RAM * 2)) ]; then
        echo -e " ${YELLOW}⚠ (recommended: ${REQUIRED_RAM}MB+)${NC}"
        [ "$STATUS" -lt 1 ] && STATUS=1
    else
        echo -e " ${GREEN}✓${NC}"
    fi

    # Disk check
    echo -n "   Disk: ${AVAILABLE_DISK}MB free"
    if [ "$AVAILABLE_DISK" -lt "$REQUIRED_DISK" ]; then
        echo -e " ${RED}✗ (required: ${REQUIRED_DISK}MB)${NC}"
        STATUS=2
    elif [ "$AVAILABLE_DISK" -lt $((REQUIRED_DISK * 2)) ]; then
        echo -e " ${YELLOW}⚠ (recommended: ${REQUIRED_DISK}MB+)${NC}"
        [ "$STATUS" -lt 1 ] && STATUS=1
    else
        echo -e " ${GREEN}✓${NC}"
    fi

    # Total RAM warning for heavy apps
    if [ "$REQUIRED_RAM" -ge 400 ] && [ "$TOTAL_RAM" -lt 2000 ]; then
        echo ""
        echo -e "   ${YELLOW}⚠ This application requires a lot of RAM.${NC}"
        echo -e "   ${YELLOW}  Recommended: a VPS plan with 2GB+ RAM${NC}"
        [ "$STATUS" -lt 1 ] && STATUS=1
    fi

    echo ""

    # Summary
    case $STATUS in
        0)
            echo -e "   ${GREEN}✅ Resources sufficient to install $APP_NAME${NC}"
            ;;
        1)
            echo -e "   ${YELLOW}⚠️  Low resources - installation possible, but it may be tight${NC}"
            ;;
        2)
            echo -e "   ${RED}❌ Not enough resources! Installing $APP_NAME may crash the server.${NC}"
            echo -e "   ${RED}   Free up space or upgrade your plan.${NC}"
            ;;
    esac

    echo ""
    return $STATUS
}

# Quick check (without fancy output)
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

# Export functions
export -f get_available_ram_mb
export -f get_available_disk_mb
export -f get_total_ram_mb
export -f check_resources
export -f quick_resource_check
