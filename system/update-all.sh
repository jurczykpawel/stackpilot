#!/bin/bash

# StackPilot - Global Update
# Updates System packages AND all Docker Stacks.
# Cleans up unused images to save disk space.
# Author: Paweł (Lazy Engineer)

set -e

_UA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    if [ -n "$_UA_DIR" ] && [ -f "$_UA_DIR/../lib/i18n.sh" ]; then
        source "$_UA_DIR/../lib/i18n.sh"
    elif [ -f /opt/stackpilot/lib/i18n.sh ]; then
        source /opt/stackpilot/lib/i18n.sh
    else
        msg() { printf "%s\n" "$1"; }
        msg_n() { printf "%s" "$1"; }
    fi
fi

LOG_FILE="/var/log/stackpilot-update.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "$(msg "$MSG_UA_START")"

# 1. System Updates
log "$(msg "$MSG_UA_APT")"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -q
sudo apt-get upgrade -y -q
sudo apt-get autoremove -y -q

# 2. Update Docker Stacks
STACKS_DIR="/opt/stacks"

if [ -d "$STACKS_DIR" ]; then
    log "$(msg "$MSG_UA_DOCKER" "$STACKS_DIR")"

    # Loop through each directory in stacks
    for STACK in "$STACKS_DIR"/*; do
        if [ -d "$STACK" ] && [ -f "$STACK/docker-compose.yaml" ]; then
            APP_NAME=$(basename "$STACK")
            log "$(msg "$MSG_UA_STACK" "$APP_NAME")"

            cd "$STACK"

            # Pull new images
            sudo docker compose pull -q

            # Restart with new images (only if updated)
            sudo docker compose up -d
        fi
    done
else
    log "$(msg "$MSG_UA_NO_STACKS" "$STACKS_DIR")"
fi

# 3. Cleanup (critical for small VPS)
log "$(msg "$MSG_UA_CLEANUP")"
sudo docker image prune -f

log "$(msg "$MSG_UA_DONE")"
