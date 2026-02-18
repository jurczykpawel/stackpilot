#!/bin/bash

# Mikrus Toolbox - n8n Logic Export
# Exports Workflows (JSON) and Credentials (Encrypted) from running n8n container.
# CRITICAL: This backs up data regardless of where the DB is (SQLite/Postgres).
# Author: Paweł (Lazy Engineer)

set -e

STACK_DIR="/opt/stacks/n8n"
BACKUP_DIR="/opt/stacks/n8n/backups"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
TARGET_DIR="$BACKUP_DIR/$TIMESTAMP"

echo "--- 📦 n8n Logical Backup Start ---"

if [ ! -d "$STACK_DIR" ]; then
    echo "❌ n8n directory not found at $STACK_DIR"
    exit 1
fi

cd "$STACK_DIR"

# Ensure backup dir exists
sudo mkdir -p "$TARGET_DIR"
sudo chown 1000:1000 "$TARGET_DIR" # n8n user inside container is usually 1000

echo "1. Exporting Workflows (JSON)..."
# We run the export command INSIDE the container
# --all: all workflows
# --pretty: readable JSON
sudo docker compose exec -T n8n n8n export:workflow --all --pretty --output=/tmp/workflows.json

# Copy out of container
# Assuming n8n user inside container has access to write to /tmp
# We need to copy it from container to host
CONTAINER_ID=$(sudo docker compose ps -q n8n)
sudo docker cp "$CONTAINER_ID:/tmp/workflows.json" "$TARGET_DIR/workflows.json"

echo "2. Exporting Credentials (Encrypted)..."
# Warning: These are encrypted with N8N_ENCRYPTION_KEY.
# You CANNOT restore them without the key from docker-compose.yaml!
sudo docker compose exec -T n8n n8n export:credentials --all --encrypted --output=/tmp/credentials.json
sudo docker cp "$CONTAINER_ID:/tmp/credentials.json" "$TARGET_DIR/credentials.json"

echo "3. Backing up Configuration (Keys)..."
# We backup the compose file because it contains the N8N_ENCRYPTION_KEY
sudo cp docker-compose.yaml "$TARGET_DIR/docker-compose.backup.yaml"
if [ -f .env ]; then
    sudo cp .env "$TARGET_DIR/.env.backup"
fi

echo "4. Compressing..."
cd "$BACKUP_DIR"
sudo tar -czf "n8n_backup_$TIMESTAMP.tar.gz" "$TIMESTAMP"
sudo rm -rf "$TIMESTAMP"

# Retention (Keep last 7)
ls -tp "n8n_backup_"* | grep -v '/$' | tail -n +8 | xargs -I {} rm -- {} 2>/dev/null || true

echo "✅ Backup saved to: $BACKUP_DIR/n8n_backup_$TIMESTAMP.tar.gz"
echo "👉 Make sure 'system/backup-core.sh' includes '$BACKUP_DIR'!"
