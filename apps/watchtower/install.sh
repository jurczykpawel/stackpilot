#!/bin/bash

# StackPilot - Watchtower
# Monitors Docker containers for image updates on a schedule.
# In monitor mode (default) sends notifications only; in update mode restarts containers.
#
# IMAGE_SIZE_MB=25  # containrrr/watchtower
#
# Optional environment variables (passed by deploy.sh):
#   NOTIFICATION_URL    — notification endpoint (ntfy://, slack://, etc.)
#   REPO_USER           — registry username for private images (e.g. GitHub username)
#   REPO_PASS           — registry token/password for private images
#   WATCHTOWER_SCHEDULE — cron6 schedule (default: "0 0 9 * * 0" = every Sunday 09:00)
#   WATCHTOWER_MODE     — "monitor" (default, notify only) or "update" (auto-restart)

set -e

APP_NAME="watchtower"
STACK_DIR="${STACK_DIR:-/opt/stacks/$APP_NAME}"

SCHEDULE="${WATCHTOWER_SCHEDULE:-0 0 9 * * 0}"
MODE="${WATCHTOWER_MODE:-monitor}"
TZ="${TZ:-Europe/Warsaw}"

echo "--- 🔄 Watchtower Setup ---"
echo "Monitors Docker containers for image updates."
echo ""

if [ "$MODE" = "update" ]; then
    MONITOR_ONLY="false"
    echo "✅ Mode: auto-update (containers will be restarted on new images)"
else
    MONITOR_ONLY="true"
    echo "✅ Mode: monitor-only (notifications sent, no automatic restarts)"
fi
echo "✅ Schedule: $SCHEDULE"

if [ -n "$NOTIFICATION_URL" ]; then
    echo "✅ Notifications: configured"
else
    echo "⚠️  No NOTIFICATION_URL set — Watchtower will run silently"
fi

if [ -n "$REPO_USER" ] && [ -n "$REPO_PASS" ]; then
    echo "✅ Registry auth: $REPO_USER"
fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      TZ: "$TZ"
      DOCKER_API_VERSION: "1.44"
      WATCHTOWER_SCHEDULE: "$SCHEDULE"
      WATCHTOWER_MONITOR_ONLY: "$MONITOR_ONLY"
      WATCHTOWER_NO_STARTUP_MESSAGE: "true"
      WATCHTOWER_INCLUDE_STOPPED: "false"
      WATCHTOWER_NOTIFICATION_URL: "${NOTIFICATION_URL:-}"
      REPO_USER: "${REPO_USER:-}"
      REPO_PASS: "${REPO_PASS:-}"
    deploy:
      resources:
        limits:
          memory: 64M
EOF

sudo docker compose up -d

echo "Checking if container started..."
sleep 3
if sudo docker compose ps --format json | grep -q '"State":"running"'; then
    echo "✅ Container is running"
else
    echo "❌ Container failed to start!"
    sudo docker compose logs --tail 20
    exit 1
fi

echo ""
echo "✅ Watchtower installed successfully"
if [ "$MODE" = "update" ]; then
    echo "🔄 Auto-update schedule: $SCHEDULE"
else
    echo "👁️  Monitoring schedule: $SCHEDULE"
fi
if [ -n "$NOTIFICATION_URL" ]; then
    echo "🔔 Notifications configured"
fi
echo ""
echo "📋 Useful commands:"
echo "   Logs:        docker logs -f watchtower"
echo "   Check now:   docker exec watchtower /watchtower --run-once"
