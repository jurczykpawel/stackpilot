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
            echo "✅ Redis: external (host, forced)"
        else
            echo "⚠️  Redis external: nothing listening on localhost:6379"
            echo "   Using bundled Redis instead."
            REDIS_HOST="$BUNDLED_NAME"
        fi
    elif [ "$MODE" = "bundled" ]; then
        REDIS_HOST="$BUNDLED_NAME"
        echo "✅ Redis: bundled (forced)"
    elif _redis_listening; then
        REDIS_HOST="host-gateway"
        echo "✅ Redis: external (detected on localhost:6379)"
    else
        REDIS_HOST="$BUNDLED_NAME"
        echo "✅ Redis: bundled (no existing instance found)"
    fi
}
