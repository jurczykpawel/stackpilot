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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Load server-exec
source "$REPO_ROOT/lib/server-exec.sh"
export SSH_ALIAS

# =============================================================================
# CONNECTION
# =============================================================================

echo ""
echo -n "🔗 Connecting to server ($SSH_ALIAS)... "
if ! server_exec "true" 2>/dev/null; then
    echo -e "${RED}✗${NC}"
    echo -e "${RED}❌ Cannot connect to server: $SSH_ALIAS${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC}"

HOSTNAME=$(server_exec "hostname" 2>/dev/null)
echo "   Host: $HOSTNAME"

# =============================================================================
# RESOURCES
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  📊 Server resources                                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

RESOURCES=$(server_exec "free -m | awk '/^Mem:/ {print \$7, \$2}'; df -m / | awk 'NR==2 {print \$4, \$2}'" 2>/dev/null)
RAM_AVAIL=$(echo "$RESOURCES" | sed -n '1p' | awk '{print $1}')
RAM_TOTAL=$(echo "$RESOURCES" | sed -n '1p' | awk '{print $2}')
DISK_AVAIL=$(echo "$RESOURCES" | sed -n '2p' | awk '{print $1}')
DISK_TOTAL=$(echo "$RESOURCES" | sed -n '2p' | awk '{print $2}')

if [ -n "$RAM_AVAIL" ] && [ -n "$RAM_TOTAL" ]; then
    RAM_USED_PCT=$(( (RAM_TOTAL - RAM_AVAIL) * 100 / RAM_TOTAL ))
    if [ "$RAM_USED_PCT" -gt 80 ]; then
        RAM_LABEL="${RED}CRITICAL${NC}"
    elif [ "$RAM_USED_PCT" -gt 60 ]; then
        RAM_LABEL="${YELLOW}TIGHT${NC}"
    else
        RAM_LABEL="${GREEN}OK${NC}"
    fi
    echo -e "   RAM:  ${RAM_AVAIL}MB / ${RAM_TOTAL}MB free (${RAM_USED_PCT}% used) — $RAM_LABEL"
else
    echo -e "   RAM:  ${YELLOW}could not read${NC}"
fi

if [ -n "$DISK_AVAIL" ] && [ -n "$DISK_TOTAL" ]; then
    DISK_USED_PCT=$(( (DISK_TOTAL - DISK_AVAIL) * 100 / DISK_TOTAL ))
    DISK_AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_AVAIL / 1024}")
    DISK_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_TOTAL / 1024}")
    if [ "$DISK_USED_PCT" -gt 85 ]; then
        DISK_LABEL="${RED}CRITICAL${NC}"
    elif [ "$DISK_USED_PCT" -gt 60 ]; then
        DISK_LABEL="${YELLOW}TIGHT${NC}"
    else
        DISK_LABEL="${GREEN}OK${NC}"
    fi
    echo -e "   Disk: ${DISK_AVAIL_GB}GB / ${DISK_TOTAL_GB}GB free (${DISK_USED_PCT}% used) — $DISK_LABEL"
else
    echo -e "   Disk: ${YELLOW}could not read${NC}"
fi

# =============================================================================
# DOCKER CONTAINERS
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  🐳 Docker containers                                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

CONTAINERS=$(server_exec "docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null" 2>/dev/null)

if [ -z "$CONTAINERS" ]; then
    echo "   (no running containers)"
else
    CONTAINER_COUNT=$(echo "$CONTAINERS" | wc -l | tr -d ' ')
    echo "   Running: $CONTAINER_COUNT"
    echo ""
    echo "$CONTAINERS" | while IFS=$'\t' read -r NAME IMAGE STATUS PORTS; do
        # Shorten status
        SHORT_STATUS=$(echo "$STATUS" | sed 's/Up /↑ /; s/ (healthy)/ ✓/; s/ (unhealthy)/ ✗/; s/ (starting)/ .../; s/ seconds/s/; s/ minutes/m/; s/ hours/h/; s/ days/d/; s/ weeks/w/')
        # Shorten ports (remove IPv6 duplicates)
        SHORT_PORTS=$(echo "$PORTS" | sed 's/, \[::\]:[0-9]*->[0-9]*\/tcp//g; s/0\.0\.0\.0://g; s/\/tcp//g')

        # Colorize status
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
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  🔌 Occupied ports                                             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

PORTS=$(server_exec "ss -tlnp 2>/dev/null | awk 'NR>1 {split(\$4,a,\":\"); port=a[length(a)]; if(port+0>0) print port}' | sort -un | tr '\n' ' '" 2>/dev/null)
echo "   $PORTS"

# =============================================================================
# STACKS
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  📦 Installed stacks                                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

STACKS_STATUS=$(server_exec "for s in /opt/stacks/*/; do name=\$(basename \"\$s\"); if [ -f \"\$s/docker-compose.yaml\" ] || [ -f \"\$s/docker-compose.yml\" ]; then state=\$(cd \"\$s\" && docker compose ps --format '{{.State}}' 2>/dev/null | head -1); echo \"\$name|\$state\"; else echo \"\$name|static\"; fi; done" 2>/dev/null)
if [ -z "$STACKS_STATUS" ]; then
    echo "   (no stacks in /opt/stacks/)"
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
        echo -e "${GREEN}✅ Server is in good shape.${NC}"
    elif [ "$HEALTH_LEVEL" -eq 1 ]; then
        echo -e "${YELLOW}⚠️  Getting tight. Consider upgrading before adding heavy services.${NC}"
    else
        echo -e "${RED}❌ Server is heavily loaded! Consider upgrading or removing unused services.${NC}"
    fi
fi
echo ""
