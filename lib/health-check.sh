#!/bin/bash

# StackPilot - Health Check Helper
# Checks if a container has started and the application is responding.
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   source "$(dirname "$0")/../../lib/health-check.sh"
#   wait_for_healthy "$APP_NAME" "$PORT" [timeout_seconds]
#
# Function returns:
#   0 - success (application is running)
#   1 - error (timeout or app not responding)
#
# Requires: lib/i18n.sh must be sourced before this file.

# Colors (if not already defined)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
NC="${NC:-\033[0m}"

# Checks if container is running and application responds to HTTP
# Arguments: APP_NAME PORT [TIMEOUT] [HEALTH_PATH]
# Uses $STACK_DIR from env if set, otherwise /opt/stacks/$APP_NAME
wait_for_healthy() {
    local APP_NAME="$1"
    local PORT="$2"
    local TIMEOUT="${3:-30}"
    local HEALTH_PATH="${4:-/}"

    local STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"
    local ELAPSED=0
    local INTERVAL=2

    echo ""
    msg "$MSG_HC_CHECKING" "$APP_NAME"

    # 1. Check if container is running
    cd "$STACK_DIR" 2>/dev/null || {
        msg "$MSG_HC_DIR_NOT_FOUND" "$STACK_DIR"
        return 1
    }

    # Wait for "running" state
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
        msg "$MSG_HC_CONTAINER_NOT_STARTED"
        echo ""
        msg "$MSG_HC_LOGS"
        sudo docker compose logs --tail 20
        return 1
    fi

    msg_n "$MSG_HC_CONTAINER_RUNNING"
    echo ""

    # 2. Check if application responds to HTTP
    msg_n "$MSG_HC_WAITING_HTTP"

    while [ $ELAPSED -lt $TIMEOUT ]; do
        # Check if curl gets a response (any response, even 401/403)
        local HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:$PORT$HEALTH_PATH" 2>/dev/null)

        if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
            echo ""
            msg "$MSG_HC_APP_RESPONDING" "$HTTP_CODE"
            return 0
        fi

        # Check if container is still running (might be crash-looping)
        if ! sudo docker compose ps --format json 2>/dev/null | grep -q '"State":"running"'; then
            echo ""
            msg "$MSG_HC_CONTAINER_STOPPED"
            echo ""
            msg "$MSG_HC_LOGS"
            sudo docker compose logs --tail 30
            return 1
        fi

        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
        echo -n "."
    done

    echo ""
    msg "$MSG_HC_TIMEOUT" "$TIMEOUT"
    echo ""
    msg "$MSG_HC_LOGS"
    sudo docker compose logs --tail 30
    return 1
}

# Quick check - only if container is running (no HTTP)
check_container_running() {
    local APP_NAME="$1"
    local STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"

    cd "$STACK_DIR" 2>/dev/null || return 1

    sleep 3
    if sudo docker compose ps --format json 2>/dev/null | grep -q '"State":"running"'; then
        msg "$MSG_HC_CONTAINER_OK" "$APP_NAME"
        return 0
    else
        msg "$MSG_HC_CONTAINER_FAIL" "$APP_NAME"
        sudo docker compose logs --tail 20
        return 1
    fi
}

# Export functions
export -f wait_for_healthy
export -f check_container_running
