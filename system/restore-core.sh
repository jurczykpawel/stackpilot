#!/bin/bash

# StackPilot - Core Restore Script
# RESTORES data from Cloud to the VPS.
# WARNING: Overwrites local data!
# Author: Paweł (Lazy Engineer)

set -e

_RC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    if [ -n "$_RC_DIR" ] && [ -f "$_RC_DIR/../lib/i18n.sh" ]; then
        source "$_RC_DIR/../lib/i18n.sh"
    elif [ -f /opt/stackpilot/lib/i18n.sh ]; then
        source /opt/stackpilot/lib/i18n.sh
    else
        msg() { printf "%s\n" "$1"; }
        msg_n() { printf "%s" "$1"; }
    fi
fi

# Configuration (Must match backup-core.sh)
BACKUP_NAME="stackpilot-backup"
REMOTE_NAME="backup_remote"
# Directories to restore.
TARGET_DIRS=(
    "/opt/dockge"
    "/opt/stacks"
)
LOG_FILE="/var/log/stackpilot-restore.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

msg "$MSG_RC_WARN1" "${TARGET_DIRS[*]}"
msg "$MSG_RC_WARN2"
read -r CONFIRM

# Accept locale-specific confirmation word
if [ "$CONFIRM" != "YES" ] && [ "$CONFIRM" != "TAK" ]; then
    msg "$MSG_RC_ABORTED"
    exit 1
fi

log "$(msg "$MSG_RC_START")"

# 1. Stop Docker Services to release file locks
log "$(msg "$MSG_RC_STOPPING")"
# We stop the socket/service to be sure everything is dead
systemctl stop docker.socket
systemctl stop docker

# 2. Perform Restore
for DIR in "${TARGET_DIRS[@]}"; do
    SRC="$REMOTE_NAME:$BACKUP_NAME$(basename "$DIR")"

    log "$(msg "$MSG_RC_RESTORING" "$SRC" "$DIR")"

    # Ensure parent dir exists
    mkdir -p "$DIR"

    # Sync DOWN from Cloud
    # --delete: remove files locally that are not present in backup (exact mirror)
    rclone sync "$SRC" "$DIR" --create-empty-src-dirs --verbose >> "$LOG_FILE" 2>&1
done

# 3. Restart Services
log "$(msg "$MSG_RC_RESTARTING")"
systemctl start docker
systemctl start docker.socket

log "$(msg "$MSG_RC_DONE")"
