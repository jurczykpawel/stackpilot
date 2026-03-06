#!/bin/bash

# StackPilot - Sellf Deploy (prod + demo)
# Single command to update both Sellf environments on the server.
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./contrib/mikrus/deploy-sellf.sh                  # deploy prod + demo from GitHub
#   ./contrib/mikrus/deploy-sellf.sh --restart        # restart without updating
#   ./contrib/mikrus/deploy-sellf.sh --only-prod      # prod only
#   ./contrib/mikrus/deploy-sellf.sh --only-demo      # demo only
#   ./contrib/mikrus/deploy-sellf.sh --ssh=ALIAS      # different server (default: vps)
#
# Environments:
#   prod  → sellf-tsa    /opt/stacks/sellf-tsa    port 3333
#   demo  → sellf-demo   /opt/stacks/sellf-demo   port 3334

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/../../local/deploy.sh"

# i18n
source "$SCRIPT_DIR/../../lib/i18n.sh"
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
NC="${NC:-\033[0m}"

# =============================================================================
# ENVIRONMENT CONFIGURATION
# =============================================================================

# prod
PROD_INSTANCE="sellf-tsa"
PROD_DIR="/opt/stacks/sellf-tsa"
PROD_PORT=3333
PROD_OLD_ENV="/scripts/docker-compose/sellf/admin-panel/.env.local"

# demo
DEMO_INSTANCE="sellf-demo"
DEMO_DIR="/opt/stacks/sellf-demo"
DEMO_PORT=3334
DEMO_OLD_ENV="/opt/stacks/sellf-sellf/admin-panel/.env.local"

# =============================================================================
# DEFAULTS
# =============================================================================

SSH_ALIAS="vps"
SKIP_PROD=false
SKIP_DEMO=false
RESTART_ONLY=false

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

for arg in "$@"; do
    case "$arg" in
        --ssh=*)     SSH_ALIAS="${arg#*=}" ;;
        --only-prod) SKIP_DEMO=true ;;
        --only-demo) SKIP_PROD=true ;;
        --restart)   RESTART_ONLY=true ;;
        --help|-h)
            cat <<EOF

Usage: ./contrib/mikrus/deploy-sellf.sh [options]

Options:
  --ssh=ALIAS   SSH alias from ~/.ssh/config (default: vps)
  --restart     Restart without updating (e.g. after .env changes)
  --only-prod   Prod only (skip demo)
  --only-demo   Demo only (skip prod)
  --help        This help

Environments:
  prod  →  PM2: sellf-tsa    port 3333
  demo  →  PM2: sellf-demo   port 3334

EOF
            exit 0
            ;;
        --*)
            echo -e "${RED}Unknown option: $arg${NC}" >&2
            echo "   Use --help to see available options." >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# VALIDATION
# =============================================================================

if [ ! -f "$DEPLOY" ]; then
    echo -e "${RED}deploy.sh not found: $DEPLOY${NC}"
    exit 1
fi

# =============================================================================
# MIGRATION: create directory + copy .env.local from old location
# =============================================================================

migrate_if_needed() {
    local INSTANCE="$1"
    local TARGET_DIR="$2"
    local OLD_ENV="$3"

    # Check if new location already exists
    if ssh "$SSH_ALIAS" "[ -d '$TARGET_DIR/admin-panel' ]" 2>/dev/null; then
        return 0
    fi

    echo -e "  ${YELLOW}New location does not exist — preparing $TARGET_DIR${NC}"

    # Create directory
    ssh "$SSH_ALIAS" "mkdir -p '$TARGET_DIR/admin-panel'"

    # Copy .env.local from old location
    if ssh "$SSH_ALIAS" "[ -f '$OLD_ENV' ]" 2>/dev/null; then
        ssh "$SSH_ALIAS" "cp '$OLD_ENV' '$TARGET_DIR/admin-panel/.env.local'"
        echo -e "  ${GREEN}Copied .env.local from $OLD_ENV${NC}"
    else
        echo -e "  ${RED}Missing $OLD_ENV${NC}"
        echo "     Create manually: $TARGET_DIR/admin-panel/.env.local"
        return 1
    fi
}

# =============================================================================
# HEADER
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
if [ "$RESTART_ONLY" = true ]; then
echo "║  🔄 Sellf Restart - prod + demo                               ║"
else
echo "║  🚀 Sellf Deploy - prod + demo                                ║"
fi
echo "╠════════════════════════════════════════════════════════════════╣"
printf "║  %-62s║\n" "Server:  $SSH_ALIAS"
printf "║  %-62s║\n" "Source:  GitHub (latest release)"
if [ "$SKIP_PROD" = true ]; then
printf "║  %-62s║\n" "Mode:    DEMO only"
elif [ "$SKIP_DEMO" = true ]; then
printf "║  %-62s║\n" "Mode:    PROD only"
fi
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# DEPLOY PROD
# =============================================================================

PROD_STATUS=0
DEMO_STATUS=0

if [ "$SKIP_PROD" = false ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}📦 PROD${NC}  $PROD_INSTANCE @ port $PROD_PORT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if migrate_if_needed "$PROD_INSTANCE" "$PROD_DIR" "$PROD_OLD_ENV"; then
        DEPLOY_ARGS="--ssh=$SSH_ALIAS --update --instance=$PROD_INSTANCE --yes"
        [ "$RESTART_ONLY" = true ] && DEPLOY_ARGS="$DEPLOY_ARGS --restart"

        if bash "$DEPLOY" sellf $DEPLOY_ARGS; then
            echo ""
            echo -e "${GREEN}PROD ready${NC}"
        else
            PROD_STATUS=1
            echo ""
            echo -e "${RED}PROD — error!${NC}"
        fi
    else
        PROD_STATUS=1
    fi
fi

# =============================================================================
# DEPLOY DEMO
# =============================================================================

if [ "$SKIP_DEMO" = false ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}🧪 DEMO${NC}  $DEMO_INSTANCE @ port $DEMO_PORT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if migrate_if_needed "$DEMO_INSTANCE" "$DEMO_DIR" "$DEMO_OLD_ENV"; then
        DEPLOY_ARGS="--ssh=$SSH_ALIAS --update --instance=$DEMO_INSTANCE --yes"
        [ "$RESTART_ONLY" = true ] && DEPLOY_ARGS="$DEPLOY_ARGS --restart"

        if bash "$DEPLOY" sellf $DEPLOY_ARGS; then
            echo ""
            echo -e "${GREEN}DEMO ready${NC}"
        else
            DEMO_STATUS=1
            echo ""
            echo -e "${RED}DEMO — error!${NC}"
        fi
    else
        DEMO_STATUS=1
    fi
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Summary"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [ "$SKIP_PROD" = false ]; then
    if [ $PROD_STATUS -eq 0 ]; then
        echo -e "  ${GREEN}PROD${NC}  $PROD_INSTANCE (port $PROD_PORT)"
    else
        echo -e "  ${RED}PROD${NC}  $PROD_INSTANCE — logs: ssh $SSH_ALIAS pm2 logs $PROD_INSTANCE"
    fi
fi

if [ "$SKIP_DEMO" = false ]; then
    if [ $DEMO_STATUS -eq 0 ]; then
        echo -e "  ${GREEN}DEMO${NC}  $DEMO_INSTANCE (port $DEMO_PORT)"
    else
        echo -e "  ${RED}DEMO${NC}  $DEMO_INSTANCE — logs: ssh $SSH_ALIAS pm2 logs $DEMO_INSTANCE"
    fi
fi

echo ""

if [ $PROD_STATUS -ne 0 ] || [ $DEMO_STATUS -ne 0 ]; then
    exit 1
fi
