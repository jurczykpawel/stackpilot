#!/bin/bash

# StackPilot - PicoClaw
# Ultra-lightweight personal AI assistant — OpenClaw alternative.
# Automate tasks via Telegram, Discord, or Slack.
# https://github.com/sipeed/picoclaw
#
# IMAGE_SIZE_MB=10
# DB_BUNDLED=false
#
# REQUIREMENTS:
#   - LLM API key (OpenRouter, Anthropic, OpenAI, etc.)
#   - Bot token (Telegram, Discord, or Slack)
#   - Minimum 64MB RAM
#
# Stack: 1 container (sipeed/picoclaw:latest)
#   - picoclaw (gateway mode - long-running bot)
#
# SECURITY: This installer applies maximum Docker isolation:
#   - Read-only filesystem
#   - All capabilities dropped (cap_drop: ALL)
#   - no-new-privileges
#   - Resource limits (128MB RAM, 1 CPU)
#   - Non-root user
#   - Docker default seccomp profile
#   - No Docker socket mount

set -e

APP_NAME="picoclaw"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-18790}

echo "--- 🤖 PicoClaw Setup ---"
echo "Ultra-lightweight AI assistant with maximum Docker isolation."
echo ""

# Port binding: always bind to 127.0.0.1 (Caddy handles public exposure)
BIND_ADDR="127.0.0.1:"

# =============================================================================
# 1. CONFIGURATION WIZARD
# =============================================================================

sudo mkdir -p "$STACK_DIR/config"
cd "$STACK_DIR"

if [ -f "$STACK_DIR/config/config.json" ]; then
    echo "✅ Configuration already exists at $STACK_DIR/config/config.json"
else
    if [ "$YES_MODE" = true ] || [ ! -t 0 ]; then
        # Create template config with placeholders for the user to fill in
        cat <<'TEMPLATEEOF' | sudo tee "$STACK_DIR/config/config.json" > /dev/null
{
  "agents": {
    "defaults": {
      "model": "openrouter/anthropic/claude-sonnet-4-20250514"
    }
  },
  "providers": {
    "openrouter": {
      "api_key": "REPLACE_WITH_API_KEY",
      "api_base": "https://openrouter.ai/api/v1"
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "token": "REPLACE_WITH_BOT_TOKEN",
      "allowed_users": [0]
    }
  }
}
TEMPLATEEOF
        sudo chmod 600 "$STACK_DIR/config/config.json"
        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  📝 Config template created                                  ║"
        echo "╠════════════════════════════════════════════════════════════════╣"
        echo "║  File: $STACK_DIR/config/config.json"
        echo "║                                                              ║"
        echo "║  Fill in the following fields:                               ║"
        echo "║    1. api_key  — your LLM provider API key                   ║"
        echo "║    2. token    — bot token (Telegram/Discord/Slack)          ║"
        echo "║    3. allowed_users — your user ID (Telegram only)           ║"
        echo "║                                                              ║"
        echo "║  LLM providers (providers section):                          ║"
        echo "║    openrouter  — https://openrouter.ai/keys                  ║"
        echo "║    anthropic   — https://console.anthropic.com/settings/keys ║"
        echo "║    openai      — https://platform.openai.com/api-keys        ║"
        echo "║                                                              ║"
        echo "║  Chat channels (channels section):                           ║"
        echo "║    telegram    — token + allowed_users                       ║"
        echo "║    discord     — token                                       ║"
        echo "║    slack       — bot_token + app_token                       ║"
        echo "║                                                              ║"
        echo "║  After editing, run deploy again.                            ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        exit 1
    fi

    echo "════════════════════════════════════════════════════════════════"
    echo "  PicoClaw Configuration Wizard"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # --- LLM Provider ---
    echo "Step 1/3: LLM Provider"
    echo ""
    echo "  1) OpenRouter (recommended - access to 100+ models)"
    echo "  2) Anthropic (Claude)"
    echo "  3) OpenAI (GPT)"
    echo ""
    read -p "  Choose provider [1]: " LLM_CHOICE
    LLM_CHOICE="${LLM_CHOICE:-1}"

    case "$LLM_CHOICE" in
        1)
            LLM_PROVIDER="openrouter"
            LLM_API_BASE="https://openrouter.ai/api/v1"
            LLM_MODEL="openrouter/anthropic/claude-sonnet-4-20250514"
            echo ""
            echo "  Get your API key at: https://openrouter.ai/keys"
            ;;
        2)
            LLM_PROVIDER="anthropic"
            LLM_API_BASE=""
            LLM_MODEL="anthropic/claude-sonnet-4-20250514"
            echo ""
            echo "  Get your API key at: https://console.anthropic.com/settings/keys"
            ;;
        3)
            LLM_PROVIDER="openai"
            LLM_API_BASE=""
            LLM_MODEL="openai/gpt-4o"
            echo ""
            echo "  Get your API key at: https://platform.openai.com/api-keys"
            ;;
        *)
            echo "❌ Invalid choice. Exiting."
            exit 1
            ;;
    esac

    echo ""
    read -p "  API key: " LLM_API_KEY
    if [ -z "$LLM_API_KEY" ]; then
        echo "❌ API key is required."
        exit 1
    fi

    echo ""
    read -p "  Model [$LLM_MODEL]: " LLM_MODEL_INPUT
    LLM_MODEL="${LLM_MODEL_INPUT:-$LLM_MODEL}"
    echo "  ✅ Provider: $LLM_PROVIDER | Model: $LLM_MODEL"
    echo ""

    # --- Chat Channel ---
    echo "Step 2/3: Chat Channel"
    echo ""
    echo "  1) Telegram (recommended)"
    echo "  2) Discord"
    echo "  3) Slack"
    echo ""
    read -p "  Choose channel [1]: " CHAT_CHOICE
    CHAT_CHOICE="${CHAT_CHOICE:-1}"

    case "$CHAT_CHOICE" in
        1)
            CHAT_CHANNEL="telegram"
            echo ""
            echo "  How to get a Telegram bot token:"
            echo "    1. Open Telegram and message @BotFather"
            echo "    2. Send /newbot and follow the prompts"
            echo "    3. Copy the token (looks like: 123456:ABC-DEF...)"
            echo ""
            read -p "  Bot token: " CHAT_TOKEN
            if [ -z "$CHAT_TOKEN" ]; then
                echo "❌ Bot token is required."
                exit 1
            fi

            echo ""
            echo "  How to get your Telegram user ID:"
            echo "    1. Open Telegram and message @userinfobot"
            echo "    2. It will reply with your user ID (a number)"
            echo ""
            read -p "  Your user ID (for authorization): " CHAT_USER_ID
            if [ -z "$CHAT_USER_ID" ]; then
                echo "❌ User ID is required (it restricts who can talk to the bot)."
                exit 1
            fi
            ;;
        2)
            CHAT_CHANNEL="discord"
            echo ""
            echo "  How to get a Discord bot token:"
            echo "    1. Go to https://discord.com/developers/applications"
            echo "    2. Create an application -> Bot -> Copy token"
            echo "    3. Enable MESSAGE CONTENT INTENT in Bot settings"
            echo ""
            read -p "  Bot token: " CHAT_TOKEN
            if [ -z "$CHAT_TOKEN" ]; then
                echo "❌ Bot token is required."
                exit 1
            fi
            CHAT_USER_ID=""
            ;;
        3)
            CHAT_CHANNEL="slack"
            echo ""
            echo "  How to get Slack tokens:"
            echo "    1. Go to https://api.slack.com/apps and create a new app"
            echo "    2. Enable Socket Mode and get the App-Level Token (xapp-...)"
            echo "    3. Under OAuth, get the Bot User OAuth Token (xoxb-...)"
            echo ""
            read -p "  Bot token (xoxb-...): " CHAT_TOKEN
            if [ -z "$CHAT_TOKEN" ]; then
                echo "❌ Bot token is required."
                exit 1
            fi
            read -p "  App token (xapp-...): " SLACK_APP_TOKEN
            if [ -z "$SLACK_APP_TOKEN" ]; then
                echo "❌ App token is required for Slack Socket Mode."
                exit 1
            fi
            CHAT_USER_ID=""
            ;;
        *)
            echo "❌ Invalid choice. Exiting."
            exit 1
            ;;
    esac

    echo "  ✅ Channel: $CHAT_CHANNEL"
    echo ""

    # --- Confirmation ---
    echo "Step 3/3: Review"
    echo ""
    echo "  LLM:     $LLM_PROVIDER ($LLM_MODEL)"
    echo "  Channel: $CHAT_CHANNEL"
    echo ""
    read -p "  Proceed with installation? [Y/n]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi

    # --- Generate config.json (PicoClaw v0.1.2: providers + channels format) ---
    echo ""
    echo "📝 Generating config.json..."

    # Build provider JSON
    PROVIDER_JSON="\"$LLM_PROVIDER\": {
      \"api_key\": \"$LLM_API_KEY\""
    if [ -n "$LLM_API_BASE" ]; then
        PROVIDER_JSON="$PROVIDER_JSON,
      \"api_base\": \"$LLM_API_BASE\""
    fi
    PROVIDER_JSON="$PROVIDER_JSON
    }"

    # Build channel JSON
    case "$CHAT_CHANNEL" in
        telegram)
            CHANNEL_JSON="\"telegram\": {
      \"enabled\": true,
      \"token\": \"$CHAT_TOKEN\",
      \"allowed_users\": [$CHAT_USER_ID]
    }"
            ;;
        discord)
            CHANNEL_JSON="\"discord\": {
      \"enabled\": true,
      \"token\": \"$CHAT_TOKEN\"
    }"
            ;;
        slack)
            CHANNEL_JSON="\"slack\": {
      \"enabled\": true,
      \"bot_token\": \"$CHAT_TOKEN\",
      \"app_token\": \"$SLACK_APP_TOKEN\"
    }"
            ;;
    esac

    cat <<CFGEOF | sudo tee "$STACK_DIR/config/config.json" > /dev/null
{
  "agents": {
    "defaults": {
      "model": "$LLM_MODEL"
    }
  },
  "providers": {
    $PROVIDER_JSON
  },
  "channels": {
    $CHANNEL_JSON
  }
}
CFGEOF

    sudo chmod 600 "$STACK_DIR/config/config.json"
    echo "✅ Configuration saved to $STACK_DIR/config/config.json"
fi

echo ""

# =============================================================================
# NOTE: We use Docker's default seccomp profile (blocks ~44 dangerous syscalls:
# reboot, mount, swapon, ptrace, etc.). A custom profile requires maintaining
# per-kernel syscall lists and breaks compatibility with newer kernels.
# Combined with cap_drop ALL + no-new-privileges, isolation is robust.

# =============================================================================
# 3. CREATE DOCKER COMPOSE
# =============================================================================

echo "📦 Creating docker-compose.yaml..."

# Create workspace directory with correct permissions (picoclaw runs as UID 1000)
sudo mkdir -p "$STACK_DIR/workspace"
sudo chown -R 1000:1000 "$STACK_DIR/workspace"
sudo chown 1000:1000 "$STACK_DIR/config/config.json"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  picoclaw:
    image: sipeed/picoclaw:latest
    container_name: picoclaw
    restart: unless-stopped

    # --- SECURITY: non-root user ---
    user: "1000:1000"
    environment:
      - HOME=/home/picoclaw

    # --- SECURITY: read-only filesystem ---
    read_only: true

    # --- SECURITY: tmpfs for temp files ---
    tmpfs:
      - /tmp:size=32M,noexec,nosuid,nodev

    # --- Volumes ---
    volumes:
      - ./config/config.json:/home/picoclaw/.picoclaw/config.json:ro
      - ./workspace:/home/picoclaw/.picoclaw/workspace

    # --- SECURITY: drop ALL capabilities ---
    cap_drop:
      - ALL

    # --- SECURITY: prevent privilege escalation ---
    security_opt:
      - no-new-privileges:true

    # --- SECURITY: resource limits ---
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: "1.0"
        reservations:
          memory: 16M
          cpus: "0.1"

    # --- SECURITY: process and file limits ---
    ulimits:
      nproc: 64
      nofile:
        soft: 1024
        hard: 2048

    # --- SECURITY: no privileged mode ---
    privileged: false

    # --- Health check ---
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:18790/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

    # --- Logging ---
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

    # --- Command ---
    command: ["gateway"]

    # --- Network ---
    networks:
      - picoclaw-net

networks:
  picoclaw-net:
    driver: bridge

volumes:
  picoclaw-workspace:
EOF

echo "✅ docker-compose.yaml created"
echo ""

# =============================================================================
# 4. START
# =============================================================================

echo "--- Starting PicoClaw ---"
sudo docker compose up -d

# Health check - use container's internal health check
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type check_container_running &>/dev/null; then
    check_container_running "$APP_NAME" || { echo "❌ Installation failed!"; exit 1; }
else
    sleep 5
    if sudo docker compose ps --format json | grep -q '"State":"running"'; then
        echo "✅ PicoClaw is running"
    else
        echo "❌ Container failed to start!"; sudo docker compose logs --tail 20; exit 1
    fi
fi

# Additional health check: verify container health status
echo ""
echo "🔍 Verifying container health..."
for i in $(seq 1 6); do
    HEALTH=$(sudo docker inspect --format='{{.State.Health.Status}}' picoclaw 2>/dev/null || echo "none")
    if [ "$HEALTH" = "healthy" ]; then
        echo "✅ Container health check: healthy"
        break
    elif [ "$HEALTH" = "none" ]; then
        echo "✅ Container is running (no health check configured in image)"
        break
    fi
    sleep 5
    echo -n "."
    if [ "$i" -eq 6 ]; then
        echo ""
        echo "⚠️  Container health check not yet passing (status: $HEALTH)"
        echo "   This may be normal during first startup. Check logs:"
        echo "   ssh ${SSH_ALIAS:-vps} 'cd $STACK_DIR && docker compose logs --tail 20'"
    fi
done

# =============================================================================
# 5. SUMMARY
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ PicoClaw installed!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "🤖 Your AI assistant is now running and connected to your chat."
echo "   Send a message to your bot to test it!"
echo ""
echo "🔒 Security hardening applied:"
echo "   • Read-only filesystem"
echo "   • All Linux capabilities dropped"
echo "   • no-new-privileges enabled"
echo "   • Docker default seccomp profile (blocks ~44 dangerous syscalls)"
echo "   • Resource limits: 128MB RAM, 1 CPU"
echo "   • Non-root user (UID 1000)"
echo "   • Process limit: 64"
echo "   • No Docker socket access"
echo ""
echo "📋 Useful commands:"
echo "   ssh ${SSH_ALIAS:-vps} 'cd $STACK_DIR && docker compose logs -f'       # Live logs"
echo "   ssh ${SSH_ALIAS:-vps} 'cd $STACK_DIR && docker compose restart'       # Restart"
echo "   ssh ${SSH_ALIAS:-vps} 'cd $STACK_DIR && docker compose down'          # Stop"
echo ""
echo "📝 Configuration: $STACK_DIR/config/config.json"
echo "   Edit the config and restart to change LLM provider, model, or channel."
