#!/bin/bash
APP_NAME="wordpress"
set -e

REDIS_SHARED_LIB="${WP_REDIS_SHARED_LIB:-$(dirname "${BASH_SOURCE[0]}")/redis-shared.sh}"
source "$REDIS_SHARED_LIB" || { echo "❌ Missing $REDIS_SHARED_LIB"; exit 1; }

# Bring the shared Redis and the sites using it up to the current configuration
if [ -f "$REDIS_SHARED_DIR/docker-compose.yaml" ]; then
    redis_shared_apply
    # Servers with only per-domain sites have no default stack to pull images for
    if [ ! -d "$STACKS_DIR/$APP_NAME" ]; then
        echo "Done. Shared Redis settings are up to date."
        exit 0
    fi
fi

source "${STACKPILOT_DIR:-/opt/stackpilot}/system/update-stack.sh"
