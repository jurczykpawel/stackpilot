#!/bin/bash

# Mikrus Toolbox - Global Update
# Updates System packages AND all Docker Stacks.
# Cleans up unused images to save disk space.
# Author: Paweł (Lazy Engineer)

set -e

LOG_FILE="/var/log/mikrus-update.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "--- 🚀 Starting System Update ---"

# 1. System Updates
log "📦 Updating APT packages..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -q
sudo apt-get upgrade -y -q
sudo apt-get autoremove -y -q

# 2. Update Docker Stacks
STACKS_DIR="/opt/stacks"

if [ -d "$STACKS_DIR" ]; then
    log "🐳 Updating Docker Stacks in $STACKS_DIR..."
    
    # Loop through each directory in stacks
    for STACK in "$STACKS_DIR"/*; do
        if [ -d "$STACK" ] && [ -f "$STACK/docker-compose.yaml" ]; then
            APP_NAME=$(basename "$STACK")
            log "   🔄 Updating $APP_NAME..."
            
            cd "$STACK"
            
            # Pull new images
            sudo docker compose pull -q
            
            # Restart with new images (only if updated)
            sudo docker compose up -d
        fi
    done
else
    log "⚠️  No stacks directory found at $STACKS_DIR. Skipping Docker updates."
fi

# 3. Cleanup (Critical for Mikrus)
log "🧹 Cleaning up unused Docker images..."
sudo docker image prune -f

log "✅ Update Complete!"
