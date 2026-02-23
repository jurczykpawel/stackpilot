# PicoClaw - Ultra-Lightweight AI Assistant

Personal AI assistant that connects to Telegram, Discord, or Slack. An open-source, self-hosted alternative to OpenClaw. 17k GitHub stars, <10MB RAM, 8MB binary.

Send a message to your bot and PicoClaw uses an LLM (via OpenRouter, Anthropic, or OpenAI) to respond, run tasks, and automate workflows -- all from your chat app.

## Installation

```bash
# Interactive (recommended for first install)
./local/deploy.sh picoclaw

# Automatic (requires pre-created config.json)
./local/deploy.sh picoclaw --ssh=vps --domain-type=local --yes
```

## Requirements

- **RAM:** 64MB minimum (~10MB typical usage)
- **Disk:** ~10MB (Docker image)
- **Database:** Not required
- **Port:** None exposed (bot communicates outbound only)

## How It Works

PicoClaw runs as a single container in "gateway" mode -- a long-running process that connects to your chat platform (Telegram, Discord, or Slack) and listens for messages. When you send a message, it forwards it to your LLM provider and returns the response.

No ports are exposed. The bot initiates all connections outward to the LLM API and chat platform. This makes it inherently more secure than web-based tools.

## Setup Guide

### 1. Get an LLM API Key

**OpenRouter (recommended)** -- access to 100+ models through one API key:
1. Go to [openrouter.ai/keys](https://openrouter.ai/keys)
2. Create an account and generate an API key
3. Fund your account (pay-per-use, typically <$0.01 per message)

Alternatively, use [Anthropic](https://console.anthropic.com/settings/keys) or [OpenAI](https://platform.openai.com/api-keys) directly.

### 2. Get a Telegram Bot Token

1. Open Telegram and search for **@BotFather**
2. Send `/newbot` and follow the prompts (choose a name and username)
3. Copy the bot token (looks like `123456789:ABCdefGHI-jklMNO_pqr`)

### 3. Get Your Telegram User ID

1. Open Telegram and search for **@userinfobot**
2. Send any message -- it replies with your user ID (a number like `123456789`)
3. This ID restricts who can talk to your bot (security measure)

### 4. Run the Installer

```bash
./local/deploy.sh picoclaw
```

The interactive wizard will ask for:
- LLM provider and API key
- Chat channel and bot token
- Telegram user ID (for authorization)

### 5. Test It

Open Telegram and send a message to your bot. It should respond within a few seconds.

## Configuration

Configuration is stored at `/opt/stacks/picoclaw/config/config.json`.

PicoClaw v0.1.2 config has three sections:
- **agents** -- default model and parameters
- **providers** -- LLM providers with API keys
- **channels** -- chat channels (Telegram, Discord, Slack)

### Telegram Example

```json
{
  "agents": {
    "defaults": {
      "model": "openrouter/anthropic/claude-sonnet-4-20250514"
    }
  },
  "providers": {
    "openrouter": {
      "api_key": "sk-or-v1-...",
      "api_base": "https://openrouter.ai/api/v1"
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "token": "123456789:ABCdefGHI-jklMNO_pqr",
      "allowed_users": [123456789]
    }
  }
}
```

### Discord Example

```json
{
  "agents": {
    "defaults": {
      "model": "anthropic/claude-sonnet-4-20250514"
    }
  },
  "providers": {
    "anthropic": {
      "api_key": "sk-ant-..."
    }
  },
  "channels": {
    "discord": {
      "enabled": true,
      "token": "MTIzNDU2Nzg5..."
    }
  }
}
```

**Inviting the bot to your Discord server:**
1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Select your app -> **Bot** -> enable **Message Content Intent**
3. Go to **OAuth2** -> **URL Generator**
4. Check scopes: `bot`, `applications.commands`
5. Check permissions (Bot Permissions):

| Permission | Required | Why |
|------------|----------|-----|
| Send Messages | **Yes** | Bot needs to respond |
| Read Message History | **Yes** | Bot reads conversation context |
| View Channels | **Yes** | Bot can see channels (General Permissions) |
| Embed Links | Recommended | Rich link previews in responses |
| Attach Files | Recommended | If the bot generates files |
| Add Reactions | Recommended | Acknowledge messages with reactions |
| Use Slash Commands | Optional | Future slash command support |

6. Copy the URL and open in browser -- select your server

### Slack Example

```json
{
  "agents": {
    "defaults": {
      "model": "openai/gpt-4o"
    }
  },
  "providers": {
    "openai": {
      "api_key": "sk-..."
    }
  },
  "channels": {
    "slack": {
      "enabled": true,
      "bot_token": "xoxb-...",
      "app_token": "xapp-..."
    }
  }
}
```

## Choosing a Model

PicoClaw is an **agent with tools** (tool use / function calling). The model must support tool use -- not all of them do.

### Paid models (recommended -- just work)

Paid models have full tool use support, no rate limits, and best quality. Via OpenRouter (one API, one account) you get access to all of them:

| Model | Cost ~100 messages | Best for |
|-------|-------------------|----------|
| `anthropic/claude-sonnet-4-20250514` | ~$0.30 | Best quality, great multilingual |
| `openai/gpt-4o` | ~$0.25 | Fast, good all-around |
| `google/gemini-2.0-flash` | ~$0.03 | Ultra cheap, fast, good quality |
| `qwen/qwen3.5-397b-a17b` | ~$0.10 | Cheap, 262k context, multimodal |

```json
{
  "agents": { "defaults": { "model": "google/gemini-2.0-flash" } },
  "providers": { "openrouter": { "api_key": "sk-or-...", "api_base": "https://openrouter.ai/api/v1" } }
}
```

Gemini Flash offers the best quality/price ratio -- ~$0.03 per 100 messages, full tool use, fast.

### Free models -- OpenRouter auto-router

```json
{
  "agents": { "defaults": { "model": "openrouter/auto" } },
  "providers": { "openrouter": { "api_key": "sk-or-...", "api_base": "https://openrouter.ai/api/v1" } }
}
```

The auto-router picks the best available free model with tool use support. Sign up at [openrouter.ai](https://openrouter.ai) -- no credit card required. Downside: free models can be rate-limited during peak hours.

### Free models -- Groq (ultra fast)

```json
{
  "agents": { "defaults": { "model": "groq/openai/gpt-oss-20b" } },
  "providers": { "groq": { "api_key": "gsk_...", "api_base": "https://api.groq.com/openai/v1" } }
}
```

Sign up at [console.groq.com](https://console.groq.com) -- no credit card required. Ultra fast responses but limited token quotas.

### Free models -- what works, what doesn't

PicoClaw sends ~3.5k tokens per request (system prompt + 13 tools). Many free models lack tool use support or have token limits too low.

**Working free models:**

| Model | Provider | Notes |
|-------|----------|-------|
| `openrouter/auto` | OpenRouter | ✅ Easiest -- auto-picks the best model |
| `groq/openai/gpt-oss-20b` | Groq | ✅ Fast, good quality |
| `groq/meta-llama/llama-4-scout-17b-16e-instruct` | Groq | ✅ Fast, lower quality |

**Models that DO NOT work:**

| Model | Problem |
|-------|---------|
| `deepseek/deepseek-r1-*` | No tool use support (reasoning model) |
| `nousresearch/hermes-3-llama-3.1-405b:free` | No tool use on free tier |
| `groq/meta-llama/llama-4-maverick-*` | Too large for Groq free tier (needs 13k+ TPM, limit is 6k) |
| `groq/moonshotai/kimi-k2-instruct` | Too large for Groq free tier |
| `groq/llama-3.3-70b-versatile` | Broken tool calling format (XML instead of JSON) |

### Multiple configs (quick switching)

Keep several config files and switch with one command:

```bash
# Switch to coding config
ssh vps 'cp /opt/stacks/picoclaw/config/config-coding.json /opt/stacks/picoclaw/config/config.json && docker restart picoclaw'

# Switch back to default
ssh vps 'cp /opt/stacks/picoclaw/config/config-default.json /opt/stacks/picoclaw/config/config.json && docker restart picoclaw'
```

---

## Security Hardening

PicoClaw is an AI agent that can execute tasks. If compromised (e.g. via prompt injection), it could potentially harm your server. That is why this installer applies the **maximum Docker isolation** available:

| Measure | What It Does |
|:--------|:-------------|
| Read-only filesystem | Container cannot write to its own filesystem |
| `cap_drop: ALL` | All Linux capabilities removed (no root-like powers) |
| `no-new-privileges` | Prevents privilege escalation inside the container |
| Custom seccomp profile | Only ~55 syscalls allowed (minimal for Go + HTTP) |
| Non-root user (UID 1000) | Process runs as unprivileged user |
| Memory limit: 128MB | Cannot consume all server RAM |
| CPU limit: 1 core | Cannot monopolize CPU |
| Process limit: 64 | Cannot fork-bomb |
| File descriptor limit: 2048 | Cannot exhaust system file descriptors |
| No Docker socket | Cannot control other containers |
| Bridge network (no host) | Isolated network namespace |
| Config mounted read-only | Cannot modify its own configuration |
| tmpfs with noexec | Temp files cannot be executed |

Even if an attacker tricks the LLM into running malicious commands, these restrictions prevent meaningful damage.

## Automatic Mode (--yes)

In `--yes` mode (or without a terminal), the installer creates a **template** `config.json` with placeholders and exits. Fill in the placeholders and run deploy again:

```bash
# First run -- creates template config
./local/deploy.sh picoclaw --ssh=vps --domain-type=local --yes

# Edit the template on the server (replace REPLACE_WITH_* placeholders)
ssh vps 'sudo nano /opt/stacks/picoclaw/config/config.json'

# Second run -- deploys with your config
./local/deploy.sh picoclaw --ssh=vps --domain-type=local --yes
```

Or create the config upfront:

```bash
ssh vps 'sudo mkdir -p /opt/stacks/picoclaw/config && sudo tee /opt/stacks/picoclaw/config/config.json > /dev/null' <<'EOF'
{
  "agents": { "defaults": { "model": "openrouter/anthropic/claude-sonnet-4-20250514" } },
  "providers": { "openrouter": { "api_key": "sk-or-YOUR-KEY", "api_base": "https://openrouter.ai/api/v1" } },
  "channels": { "telegram": { "enabled": true, "token": "YOUR-BOT-TOKEN", "allowed_users": [YOUR_USER_ID] } }
}
EOF

./local/deploy.sh picoclaw --ssh=vps --domain-type=local --yes
```

## Troubleshooting

### Bot does not respond

1. Check if the container is running:
   ```bash
   ssh vps 'cd /opt/stacks/picoclaw && docker compose ps'
   ```

2. Check the logs:
   ```bash
   ssh vps 'cd /opt/stacks/picoclaw && docker compose logs --tail 50'
   ```

3. Common causes:
   - **Invalid bot token** -- re-check with @BotFather
   - **Invalid API key** -- verify at your LLM provider's dashboard
   - **Wrong user ID** -- check with @userinfobot (Telegram)

### Container keeps restarting

Check the logs for errors. The most common cause is an invalid `config.json`:
```bash
ssh vps 'cd /opt/stacks/picoclaw && docker compose logs --tail 30'
```

### Permission denied errors

The container runs as UID 1000. Ensure the workspace directory has correct ownership:
```bash
ssh vps 'sudo chown -R 1000:1000 /opt/stacks/picoclaw/workspace'
```

### Changing the LLM model or provider

Edit the config and restart:
```bash
ssh vps 'sudo nano /opt/stacks/picoclaw/config/config.json'
ssh vps 'cd /opt/stacks/picoclaw && docker compose restart'
```

## Backup

PicoClaw is mostly stateless. Back up:
- `config/config.json` -- your configuration (contains API keys)
- `workspace/` -- any files the bot has created

```bash
ssh vps 'tar -czf /tmp/picoclaw-backup.tar.gz -C /opt/stacks/picoclaw config workspace'
scp vps:/tmp/picoclaw-backup.tar.gz ./picoclaw-backup.tar.gz
```
