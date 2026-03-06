#!/bin/bash

# StackPilot - Redis Detection
# Shared logic for Redis detection (external vs bundled).
# Used by: apps/wordpress/install.sh, apps/postiz/install.sh
#
# Usage:
#   source /opt/stackpilot/lib/redis-detect.sh
#   detect_redis "$MODE" "$BUNDLED_NAME"  # MODE: auto|external|bundled
#
# After calling, sets:
#   REDIS_HOST  - "host-gateway" (external) or service name (bundled)
#
# Redis password:
#   If external Redis requires a password, user sets REDIS_PASS env var.
#   detect_redis does NOT touch REDIS_PASS - that's the caller's responsibility.
#
# Parameters:
#   $1 - mode: auto|external|bundled
#   $2 - bundled Redis service name (default: "redis")

# i18n
_RD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_RD_DIR/i18n.sh"
fi

detect_redis() {
    local MODE="${1:-auto}"
    local BUNDLED_NAME="${2:-redis}"

    REDIS_HOST=""

    # Check if something is listening on port 6379
    _redis_listening() {
        ss -tlnp 2>/dev/null | grep -q ':6379 ' \
            || nc -z localhost 6379 2>/dev/null
    }

    if [ "$MODE" = "external" ]; then
        if _redis_listening; then
            REDIS_HOST="host-gateway"
            msg "$MSG_REDIS_EXTERNAL_FORCED"
        else
            msg "$MSG_REDIS_EXTERNAL_FALLBACK"
            msg "$MSG_REDIS_EXTERNAL_FALLBACK_HINT"
            REDIS_HOST="$BUNDLED_NAME"
        fi
    elif [ "$MODE" = "bundled" ]; then
        REDIS_HOST="$BUNDLED_NAME"
        msg "$MSG_REDIS_BUNDLED_FORCED"
    elif _redis_listening; then
        REDIS_HOST="host-gateway"
        msg "$MSG_REDIS_EXTERNAL_DETECTED"
    else
        REDIS_HOST="$BUNDLED_NAME"
        msg "$MSG_REDIS_BUNDLED_DEFAULT"
    fi
}
