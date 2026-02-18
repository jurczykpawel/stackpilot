#!/bin/bash

# Mikrus Toolbox - Docker MCP Server
# Provides a Model Context Protocol (MCP) interface for Docker.
# Allows AI Agents (Claude, Gemini) to manage your Mikrus containers.
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=100  # alpine + socat (~100MB)

set -e

APP_NAME="mcp-docker"
STACK_DIR="/opt/stacks/$APP_NAME"

echo "--- 🤖 Docker MCP Server Setup ---"
echo "This will allow AI Agents to interact with your Docker containers via SSH."

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# Using the community-standard MCP server for Docker
cat <<EOF | sudo tee docker-compose.yaml

services:
  mcp-docker:
    image: mcp/docker:latest
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    deploy:
      resources:
        limits:
          memory: 128M

EOF

sudo docker compose up -d

# Health check (MCP nie ma HTTP)
source /opt/mikrus-toolbox/lib/health-check.sh 2>/dev/null || true
if type check_container_running &>/dev/null; then
    check_container_running "$APP_NAME" || { echo "❌ Instalacja nie powiodła się!"; exit 1; }
else
    sleep 3
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ Docker MCP Server działa"
    else
        echo "❌ Kontener nie wystartował!"; sudo docker compose logs --tail 20; exit 1
    fi
fi
echo ""
echo "💡 How to use with your local AI Agent:"
echo "   Add this to your Claude/Cursor/Agent config:"
echo ""
echo "   {"
echo "     \"mcpServers\": {"
echo "       \"docker-mikrus\": {"
echo "         \"command\": \"ssh\","
echo "         \"args\": [\"mikrus\", \"docker\", \"run\", \"-i\", \"--rm\", \"-v\", \"/var/run/docker.sock:/var/run/docker.sock\", \"mcp/docker\"]"
echo "       }"
echo "     }"
echo "   }"
echo ""
echo "   Now your AI can say: 'Show me my containers on Mikrus' or 'Check logs of n8n'."
