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

# Fallback msg()/msg_n() when health-check.sh is sourced without i18n.sh
if ! type msg &>/dev/null; then
    MSG_HC_CHECKING="${MSG_HC_CHECKING:-Checking %s...}"
    MSG_HC_DIR_NOT_FOUND="${MSG_HC_DIR_NOT_FOUND:-Stack directory not found: %s}"
    MSG_HC_CONTAINER_NOT_STARTED="${MSG_HC_CONTAINER_NOT_STARTED:-Container did not start.}"
    MSG_HC_LOGS="${MSG_HC_LOGS:-Logs:}"
    MSG_HC_CONTAINER_RUNNING="${MSG_HC_CONTAINER_RUNNING:- Container running.}"
    MSG_HC_WAITING_HTTP="${MSG_HC_WAITING_HTTP:- Waiting for HTTP response...}"
    MSG_HC_APP_RESPONDING="${MSG_HC_APP_RESPONDING:- App responding (HTTP %s)}"
    MSG_HC_CONTAINER_STOPPED="${MSG_HC_CONTAINER_STOPPED:- Container stopped.}"
    MSG_HC_TIMEOUT="${MSG_HC_TIMEOUT:-Timeout after %ss.}"
    MSG_HC_CONTAINER_OK="${MSG_HC_CONTAINER_OK:-Container running: %s}"
    MSG_HC_CONTAINER_FAIL="${MSG_HC_CONTAINER_FAIL:-Container not running: %s}"
    msg()   { local fmt="$1"; shift; printf "${fmt}\n" "$@"; }
    msg_n() { local fmt="$1"; shift; printf "${fmt}"   "$@"; }
fi

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
