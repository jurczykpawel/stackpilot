#!/bin/bash

# StackPilot - Core Backup Script
# Uses Rclone to sync data to a configured remote.
# Author: Paweł (Lazy Engineer)

set -e

_BC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    if [ -n "$_BC_DIR" ] && [ -f "$_BC_DIR/../lib/i18n.sh" ]; then
        source "$_BC_DIR/../lib/i18n.sh"
    elif [ -f /opt/stackpilot/lib/i18n.sh ]; then
        source /opt/stackpilot/lib/i18n.sh
    else
        msg() { printf "%s\n" "$1"; }
        msg_n() { printf "%s" "$1"; }
    fi
fi

# Configuration
BACKUP_NAME="stackpilot-backup"
REMOTE_NAME="backup_remote" # Must match what we configure in rclone.conf
SOURCE_DIRS=(
    "/opt/dockge"
    "/opt/stacks"
    # Add other critical paths here.
    # We avoid full docker volumes backup by default as it can be huge and inconsistent without stopping containers.
    # Ideally, apps should map data to /opt/stacks/app-name/data
)
LOG_FILE="/var/log/stackpilot-backup.log"

# Exclusions - files that can be re-downloaded/rebuilt
EXCLUDES=(
    "node_modules/**"       # npm/bun dependencies
    ".next/**"              # Next.js build output
    ".nuxt/**"              # Nuxt.js build output
    "build/**"              # Generic build directories
    "dist/**"               # Generic dist directories
    ".git/**"               # Git history
    "*.log"                 # Log files
    ".cache/**"             # Cache directories
)

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "$(msg "$MSG_BC_START")"

# 1. Check if Rclone is configured
if ! command -v rclone &> /dev/null; then
    log "$(msg "$MSG_BC_NO_RCLONE")"
    exit 1
fi

if ! rclone listremotes | grep -q "$REMOTE_NAME"; then
    log "$(msg "$MSG_BC_NO_REMOTE" "$REMOTE_NAME")"
    exit 1
fi

# 2. Prepare Backup Staging (Optional - direct sync is better for bandwidth)
# We will sync directly from filesystem to remote to save local disk space (small VPS has limited disk)

# 3. Build exclude flags
EXCLUDE_FLAGS=""
for PATTERN in "${EXCLUDES[@]}"; do
    EXCLUDE_FLAGS="$EXCLUDE_FLAGS --exclude=$PATTERN"
done

# 4. Perform Sync
for DIR in "${SOURCE_DIRS[@]}"; do
    if [ -d "$DIR" ]; then
        DEST="$REMOTE_NAME:$BACKUP_NAME$(basename "$DIR")"
        log "$(msg "$MSG_BC_SYNCING" "$DIR" "$DEST")"

        # --update: skip files that are newer on destination
        # --transfers 1: limited concurrency to save RAM/CPU
        # shellcheck disable=SC2086
        rclone sync "$DIR" "$DEST" --create-empty-src-dirs --update --transfers 1 --verbose $EXCLUDE_FLAGS >> "$LOG_FILE" 2>&1
    else
        log "$(msg "$MSG_BC_DIR_SKIP" "$DIR")"
    fi
done

log "$(msg "$MSG_BC_DONE")"
