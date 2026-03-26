#!/bin/bash

# StackPilot - KSeF Gateway Update
# Pulls latest Docker images and restarts.
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   ./local/deploy.sh ksef-gateway --ssh=vps --update
#   ./local/deploy.sh ksef-gateway --ssh=vps --update --restart  (restart only, no pull)

set -e

APP_NAME="ksef-gateway"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-8080}
RESTART_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --restart) RESTART_ONLY=true; shift ;;
    esac
done

if [ ! -d "$STACK_DIR" ]; then
    echo "KSeF Gateway not installed at $STACK_DIR"
    echo "Run install first: ./local/deploy.sh ksef-gateway --ssh=vps"
    exit 1
fi

cd "$STACK_DIR"

if [ "$RESTART_ONLY" = true ]; then
    echo "Restarting KSeF Gateway..."
    sudo docker compose restart
else
    echo "Pulling latest images..."
    sudo docker compose pull

    echo "Restarting with new images..."
    sudo docker compose up -d
fi

# Health check
echo "Waiting for KSeF Gateway..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 45 "/health" || { echo "Update failed!"; exit 1; }
else
    for i in $(seq 1 5); do
        sleep 10
        if curl -sf "http://localhost:$PORT/health" > /dev/null 2>&1; then
            echo "KSeF Gateway updated (after $((i*10))s)"
            break
        fi
        if [ "$i" -eq 5 ]; then
            echo "Health check failed after 50s!"
            sudo docker compose logs --tail 20
            exit 1
        fi
    done
fi

echo ""
echo "KSeF Gateway updated!"
echo "API: $(sudo docker compose images ksef-api --format '{{.Tag}}')"
echo "PDF: $(sudo docker compose images ksef-pdf --format '{{.Tag}}')"
