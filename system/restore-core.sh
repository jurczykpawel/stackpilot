#!/bin/bash

# StackPilot - Core Restore Script
# RESTORES data from Cloud to the VPS.
# WARNING: Overwrites local data!
# Author: Paweł (Lazy Engineer)

set -e

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

echo "⚠️  WARNING: This will STOP all Docker services and OVERWRITE data in: ${TARGET_DIRS[*]}"
echo "⚠️  Are you sure you want to proceed? (Type 'YES' to confirm)"
read -r CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

log "--- Starting Restore Procedure ---"

# 1. Stop Docker Services to release file locks
log "🛑 Stopping Docker services..."
# We stop the socket/service to be sure everything is dead
systemctl stop docker.socket
systemctl stop docker

# 2. Perform Restore
for DIR in "${TARGET_DIRS[@]}"; do
    SRC="$REMOTE_NAME:$BACKUP_NAME$(basename "$DIR")"

    log "📥 Restoring $SRC to $DIR..."

    # Ensure parent dir exists
    mkdir -p "$DIR"

    # Sync DOWN from Cloud
    # --delete: remove files locally that are not present in backup (exact mirror)
    rclone sync "$SRC" "$DIR" --create-empty-src-dirs --verbose >> "$LOG_FILE" 2>&1
done

# 3. Restart Services
log "🟢 Restarting Docker services..."
systemctl start docker
systemctl start docker.socket

log "✅ Restore completed successfully. Your system is back in time."
