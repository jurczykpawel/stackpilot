#!/bin/bash

# StackPilot - Server Status
# Shows server state: RAM, disk, containers, ports, stacks.
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   ./local/server-status.sh [--ssh=ALIAS]
#
# Examples:
#   ./local/server-status.sh                # default alias: vps
#   ./local/server-status.sh --ssh=hanna    # different server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors must be defined BEFORE sourcing server-exec.sh (which loads i18n)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Load server-exec (which also loads i18n)
source "$REPO_ROOT/lib/server-exec.sh"

_SS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_SS_DIR/../lib/i18n.sh"
fi

# Parse arguments
SSH_ALIAS="vps"
for arg in "$@"; do
    case "$arg" in
        --ssh=*) SSH_ALIAS="${arg#--ssh=}" ;;
        -h|--help)
            echo "Usage: $0 [--ssh=ALIAS]"
            echo ""
            echo "Shows VPS server status:"
            echo "  - RAM and disk"
            echo "  - Running Docker containers"
            echo "  - Occupied ports"
            echo "  - Installed stacks"
            echo ""
            echo "Options:"
            echo "  --ssh=ALIAS   SSH alias (default: vps)"
            exit 0
            ;;
    esac
done

export SSH_ALIAS

# =============================================================================
# CONNECTION
# =============================================================================

echo ""
msg_n "$MSG_SS_CONNECTING" "$SSH_ALIAS"
if ! server_exec "true" 2>/dev/null; then
    msg "$MSG_SS_CONNECT_FAIL"
    msg "$MSG_SS_CONNECT_ERR" "$SSH_ALIAS"
    exit 1
fi
msg "$MSG_SS_CONNECT_OK"

HOSTNAME=$(server_exec "hostname" 2>/dev/null)
msg "$MSG_SS_HOST" "$HOSTNAME"

# =============================================================================
# RESOURCES
# =============================================================================

echo ""
msg "$MSG_SS_RES_HEADER_TOP"
msg "$MSG_SS_RES_HEADER_TITLE"
msg "$MSG_SS_RES_HEADER_BOT"
echo ""

RESOURCES=$(server_exec "free -m | awk '/^Mem:/ {print \$7, \$2}'; df -m / | awk 'NR==2 {print \$4, \$2}'" 2>/dev/null)
RAM_AVAIL=$(echo "$RESOURCES" | sed -n '1p' | awk '{print $1}')
RAM_TOTAL=$(echo "$RESOURCES" | sed -n '1p' | awk '{print $2}')
DISK_AVAIL=$(echo "$RESOURCES" | sed -n '2p' | awk '{print $1}')
DISK_TOTAL=$(echo "$RESOURCES" | sed -n '2p' | awk '{print $2}')

if [ -n "$RAM_AVAIL" ] && [ -n "$RAM_TOTAL" ]; then
    RAM_USED_PCT=$(( (RAM_TOTAL - RAM_AVAIL) * 100 / RAM_TOTAL ))
    if [ "$RAM_USED_PCT" -gt 80 ]; then
        msg "$MSG_SS_RAM_CRIT" "$RAM_AVAIL" "$RAM_TOTAL" "$RAM_USED_PCT"
    elif [ "$RAM_USED_PCT" -gt 60 ]; then
        msg "$MSG_SS_RAM_TIGHT" "$RAM_AVAIL" "$RAM_TOTAL" "$RAM_USED_PCT"
    else
        msg "$MSG_SS_RAM_OK" "$RAM_AVAIL" "$RAM_TOTAL" "$RAM_USED_PCT"
    fi
else
    msg "$MSG_SS_RAM_ERR"
fi

if [ -n "$DISK_AVAIL" ] && [ -n "$DISK_TOTAL" ]; then
    DISK_USED_PCT=$(( (DISK_TOTAL - DISK_AVAIL) * 100 / DISK_TOTAL ))
    DISK_AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_AVAIL / 1024}")
    DISK_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_TOTAL / 1024}")
    if [ "$DISK_USED_PCT" -gt 85 ]; then
        msg "$MSG_SS_DISK_CRIT" "$DISK_AVAIL_GB" "$DISK_TOTAL_GB" "$DISK_USED_PCT"
    elif [ "$DISK_USED_PCT" -gt 60 ]; then
        msg "$MSG_SS_DISK_TIGHT" "$DISK_AVAIL_GB" "$DISK_TOTAL_GB" "$DISK_USED_PCT"
    else
        msg "$MSG_SS_DISK_OK" "$DISK_AVAIL_GB" "$DISK_TOTAL_GB" "$DISK_USED_PCT"
    fi
else
    msg "$MSG_SS_DISK_ERR"
fi

# =============================================================================
# DOCKER CONTAINERS
# =============================================================================

echo ""
msg "$MSG_SS_DOCKER_HEADER_TOP"
msg "$MSG_SS_DOCKER_HEADER_TITLE"
msg "$MSG_SS_DOCKER_HEADER_BOT"
echo ""

CONTAINERS=$(server_exec "docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null" 2>/dev/null)

if [ -z "$CONTAINERS" ]; then
    msg "$MSG_SS_DOCKER_NONE"
else
    CONTAINER_COUNT=$(echo "$CONTAINERS" | wc -l | tr -d ' ')
    msg "$MSG_SS_DOCKER_COUNT" "$CONTAINER_COUNT"
    echo ""
    echo "$CONTAINERS" | while IFS=$'\t' read -r NAME IMAGE STATUS PORTS; do
        # Shorten status
        SHORT_STATUS=$(echo "$STATUS" | sed 's/Up /↑ /; s/ (healthy)/ ✓/; s/ (unhealthy)/ ✗/; s/ (starting)/ .../; s/ seconds/s/; s/ minutes/m/; s/ hours/h/; s/ days/d/; s/ weeks/w/')
        # Shorten ports (remove IPv6 duplicates)
        SHORT_PORTS=$(echo "$PORTS" | sed 's/, \[::\]:[0-9]*->[0-9]*\/tcp//g; s/0\.0\.0\.0://g; s/\/tcp//g')

        # Colorize status (inline formatting — dynamic, not translatable)
        if echo "$STATUS" | grep -q "healthy"; then
            echo -e "   ${GREEN}●${NC} $NAME  $SHORT_STATUS  $SHORT_PORTS"
        elif echo "$STATUS" | grep -q "unhealthy"; then
            echo -e "   ${RED}●${NC} $NAME  $SHORT_STATUS  $SHORT_PORTS"
        else
            echo -e "   ${YELLOW}●${NC} $NAME  $SHORT_STATUS  $SHORT_PORTS"
        fi
    done
fi

# =============================================================================
# OCCUPIED PORTS
# =============================================================================

echo ""
msg "$MSG_SS_PORTS_HEADER_TOP"
msg "$MSG_SS_PORTS_HEADER_TITLE"
msg "$MSG_SS_PORTS_HEADER_BOT"
echo ""

PORTS=$(server_exec "ss -tlnp 2>/dev/null | awk 'NR>1 {split(\$4,a,\":\"); port=a[length(a)]; if(port+0>0) print port}' | sort -un | tr '\n' ' '" 2>/dev/null)
echo "   $PORTS"

# =============================================================================
# STACKS
# =============================================================================

echo ""
msg "$MSG_SS_STACKS_HEADER_TOP"
msg "$MSG_SS_STACKS_HEADER_TITLE"
msg "$MSG_SS_STACKS_HEADER_BOT"
echo ""

STACKS_STATUS=$(server_exec "for s in /opt/stacks/*/; do name=\$(basename \"\$s\"); if [ -f \"\$s/docker-compose.yaml\" ] || [ -f \"\$s/docker-compose.yml\" ]; then state=\$(cd \"\$s\" && docker compose ps --format '{{.State}}' 2>/dev/null | head -1); echo \"\$name|\$state\"; else echo \"\$name|static\"; fi; done" 2>/dev/null)
if [ -z "$STACKS_STATUS" ]; then
    msg "$MSG_SS_STACKS_NONE"
else
    echo "$STACKS_STATUS" | while IFS='|' read -r stack state; do
        if [ "$state" = "static" ]; then
            echo -e "   ${BLUE}●${NC} $stack (files)"
        elif [ "$state" = "running" ]; then
            echo -e "   ${GREEN}●${NC} $stack"
        elif [ -n "$state" ]; then
            echo -e "   ${RED}●${NC} $stack ($state)"
        else
            echo -e "   ${RED}●${NC} $stack (stopped)"
        fi
    done
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
if [ -n "$RAM_AVAIL" ] && [ -n "$DISK_AVAIL" ]; then
    HEALTH_LEVEL=0
    [ "${RAM_USED_PCT:-0}" -gt 60 ] && HEALTH_LEVEL=1
    [ "${RAM_USED_PCT:-0}" -gt 80 ] && HEALTH_LEVEL=2
    [ "${DISK_USED_PCT:-0}" -gt 60 ] && [ "$HEALTH_LEVEL" -lt 1 ] && HEALTH_LEVEL=1
    [ "${DISK_USED_PCT:-0}" -gt 85 ] && HEALTH_LEVEL=2

    if [ "$HEALTH_LEVEL" -eq 0 ]; then
        msg "$MSG_SS_SUMMARY_OK"
    elif [ "$HEALTH_LEVEL" -eq 1 ]; then
        msg "$MSG_SS_SUMMARY_TIGHT"
    else
        msg "$MSG_SS_SUMMARY_CRIT"
    fi
fi
echo ""
