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

# i18n
_RC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_RC_DIR/i18n.sh"
fi

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
    printf "║  %s\n" "$(msg "$MSG_RC_HEADER")                                  ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    # RAM check
    printf "$(msg "$MSG_RC_RAM_AVAILABLE")" "$AVAILABLE_RAM"
    if [ "$AVAILABLE_RAM" -lt "$REQUIRED_RAM" ]; then
        msg "$MSG_RC_RAM_FAIL" "$REQUIRED_RAM"
        STATUS=2
    elif [ "$AVAILABLE_RAM" -lt $((REQUIRED_RAM * 2)) ]; then
        msg "$MSG_RC_RAM_WARN" "$REQUIRED_RAM"
        [ "$STATUS" -lt 1 ] && STATUS=1
    else
        msg "$MSG_RC_RAM_OK"
    fi

    # Disk check
    printf "$(msg "$MSG_RC_DISK_FREE")" "$AVAILABLE_DISK"
    if [ "$AVAILABLE_DISK" -lt "$REQUIRED_DISK" ]; then
        msg "$MSG_RC_DISK_FAIL" "$REQUIRED_DISK"
        STATUS=2
    elif [ "$AVAILABLE_DISK" -lt $((REQUIRED_DISK * 2)) ]; then
        msg "$MSG_RC_DISK_WARN" "$REQUIRED_DISK"
        [ "$STATUS" -lt 1 ] && STATUS=1
    else
        msg "$MSG_RC_DISK_OK"
    fi

    # Total RAM warning for heavy apps
    if [ "$REQUIRED_RAM" -ge 400 ] && [ "$TOTAL_RAM" -lt 2000 ]; then
        echo ""
        msg "$MSG_RC_HEAVY_APP"
        msg "$MSG_RC_HEAVY_APP_REC"
        [ "$STATUS" -lt 1 ] && STATUS=1
    fi

    echo ""

    # Summary
    case $STATUS in
        0)
            msg "$MSG_RC_OK" "$APP_NAME"
            ;;
        1)
            msg "$MSG_RC_WARN"
            ;;
        2)
            msg "$MSG_RC_FAIL" "$APP_NAME"
            msg "$MSG_RC_FAIL_HINT"
            ;;
    esac

    # Provider-specific upgrade suggestion (e.g. Mikrus plan recommendations)
    if [ "$STATUS" -gt 0 ] && type provider_upgrade_suggestion &>/dev/null; then
        provider_upgrade_suggestion "$STATUS" "$REQUIRED_RAM"
    fi

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
