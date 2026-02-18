#!/bin/bash

# Mikrus Toolbox - Core Backup Script
# Uses Rclone to sync data to a configured remote.
# Author: Paweł (Lazy Engineer)

set -e

# Configuration
BACKUP_NAME="mikrus-backup"
REMOTE_NAME="backup_remote" # Must match what we configure in rclone.conf
SOURCE_DIRS=(
    "/opt/dockge"
    "/opt/stacks"
    # Add other critical paths here.
    # We avoid full docker volumes backup by default as it can be huge and inconsistent without stopping containers.
    # Ideally, apps should map data to /opt/stacks/app-name/data
)
LOG_FILE="/var/log/mikrus-backup.log"

# Wykluczenia - pliki które można pobrać/zbudować ponownie
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

log "--- Starting Backup ---"

# 1. Check if Rclone is configured
if ! command -v rclone &> /dev/null; then
    log "❌ Rclone not installed. Install it first."
    exit 1
fi

if ! rclone listremotes | grep -q "$REMOTE_NAME"; then
    log "❌ Remote '$REMOTE_NAME' not configured in rclone."
    exit 1
fi

# 2. Prepare Backup Staging (Optional - direct sync is better for bandwidth)
# We will sync directly from filesystem to remote to save local disk space (Mikrus has small disk)

# 3. Build exclude flags
EXCLUDE_FLAGS=""
for PATTERN in "${EXCLUDES[@]}"; do
    EXCLUDE_FLAGS="$EXCLUDE_FLAGS --exclude=$PATTERN"
done

# 4. Perform Sync
for DIR in "${SOURCE_DIRS[@]}"; do
    if [ -d "$DIR" ]; then
        DEST="$REMOTE_NAME:$BACKUP_NAME$(basename "$DIR")"
        log "📤 Syncing $DIR to $DEST..."

        # --update: skip files that are newer on destination
        # --transfers 1: limited concurrency to save RAM/CPU
        # shellcheck disable=SC2086
        rclone sync "$DIR" "$DEST" --create-empty-src-dirs --update --transfers 1 --verbose $EXCLUDE_FLAGS >> "$LOG_FILE" 2>&1
    else
        log "⚠️ Directory $DIR does not exist. Skipping."
    fi
done

log "✅ Backup completed successfully."
