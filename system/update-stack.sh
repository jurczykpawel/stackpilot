#!/bin/bash

# StackPilot - Generic Docker Compose Stack Updater
# Pulls the latest image and restarts the stack.
# Author: Paweł (Lazy Engineer)
#
# Usage: set APP_NAME before sourcing, or run directly with APP_NAME env var.
#   APP_NAME="n8n" source /opt/stackpilot/system/update-stack.sh
#   APP_NAME="n8n" bash /opt/stackpilot/system/update-stack.sh

set -e

if [ -z "${APP_NAME:-}" ]; then
    echo "Error: APP_NAME is not set"
    exit 1
fi

STACK_DIR="/opt/stacks/$APP_NAME"

if [ ! -d "$STACK_DIR" ]; then
    echo "Error: $STACK_DIR not found. Is $APP_NAME installed?"
    exit 1
fi

cd "$STACK_DIR"

echo "--- $APP_NAME Update ---"

echo "Pulling latest images..."
sudo docker compose pull

echo "Restarting stack..."
sudo docker compose up -d

echo "Cleaning up old images..."
sudo docker image prune -f

echo "Done. $APP_NAME updated."
