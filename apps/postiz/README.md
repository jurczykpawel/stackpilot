# Postiz - AI-Powered Social Media Scheduler

Alternative to Buffer/Hootsuite. Schedule posts to Twitter/X, LinkedIn, Instagram, Facebook, TikTok and 20+ more platforms.

## Installation

```bash
./local/deploy.sh postiz --ssh=ALIAS --domain-type=cloudflare --domain=postiz.example.com
```

### Options

```bash
# Default: bundled PostgreSQL + Redis (zero config)
./local/deploy.sh postiz --ssh=ALIAS --domain-type=cloudflare --domain=postiz.example.com

# External PostgreSQL
./local/deploy.sh postiz --ssh=ALIAS --db-source=custom --domain-type=cloudflare --domain=postiz.example.com

# External Redis (auto-detected on host)
POSTIZ_REDIS=external ./local/deploy.sh postiz --ssh=ALIAS --domain-type=cloudflare --domain=postiz.example.com
```

## Requirements

- **RAM:** 4GB minimum (~3.5-4GB total: Postiz ~3GB + Temporal ~512M + PostgreSQL ~256M + Redis ~128M)
- **Disk:** ~3.5GB (Docker images)
- **Port:** 5000 (main app)
- **Database:** PostgreSQL 17 (bundled by default, or external via `--db-source=custom`)
- **Domain:** required (HTTPS needed for OAuth callbacks)

> **Dedicated server recommended.** Postiz alone peaks at ~2.2GB RAM during webpack build. Do not install alongside other heavy services.

## Stack (4-6 containers)

| Container | Image | RAM | Role | Bundled? |
|-----------|-------|-----|------|----------|
| postiz | ghcr.io/gitroomhq/postiz-app:latest | ~3GB | App (Next.js + Nest.js) | always |
| postiz-postgres | postgres:17-alpine | ~256MB | Postiz database | default (skip with `--db-source=custom`) |
| postiz-redis | redis:7.2-alpine | ~128MB | Cache + queues | default (skip with `POSTIZ_REDIS=external`) |
| temporal | temporalio/auto-setup:1.29.3 | ~512MB | Workflow engine | always |
| temporal-postgresql | postgres:16-alpine | ~256MB | Temporal database | always |
| temporal-ui | temporalio/ui:2.34.0 | ~256MB | Temporal panel | always |

> **Temporal UI port:** defaults to `8080`. If that port is occupied (e.g. by NocoDB), install.sh auto-increments to find a free port. Check the actual port in the compose file after installation.

## After Installation

1. Open the app in browser → create an admin account
2. **Disable registration** after creating your account:
   ```bash
   ssh ALIAS 'cd /opt/stacks/postiz && sed -i "/IS_GENERAL/a\      - DISABLE_REGISTRATION=true" docker-compose.yaml && docker compose up -d'
   ```
3. Fill in API keys for the platforms you want to use:
   ```bash
   ssh ALIAS 'nano /opt/stacks/postiz/.env'
   # After saving:
   ssh ALIAS 'cd /opt/stacks/postiz && docker compose up -d'
   ```

The `.env` file is downloaded automatically from the official Postiz repo during installation.

## Supported Platforms

Twitter/X, LinkedIn, Instagram, Facebook, TikTok, YouTube, Pinterest, Reddit, Mastodon, Bluesky, Threads, Discord, Slack, Telegram and more (20+).

Platform-specific notes:

- **Facebook/Instagram:** switch app from Development → Live (otherwise posts are visible only to you!)
- **LinkedIn:** add the "Advertising API" product (without it tokens don't refresh!)
- **TikTok:** domain with uploads must be verified in TikTok Developer Account
- **YouTube:** after configuring Brand Account, wait ~5h for propagation
- **Threads:** complex setup — [docs.postiz.com/providers/threads](https://docs.postiz.com/providers/threads)
- **Discord/Slack:** app icon is required (without it you get 404)

Docs: [docs.postiz.com/providers](https://docs.postiz.com/providers)

## API & MCP

- **API:** `https://<domain>/api/public/v1`
- **MCP (built-in):** `https://<domain>/mcp/<API-KEY>/sse`
- **Auth:** API key from Settings, `Authorization` header
- **Rate limit:** 30 req/h

```json
{
  "mcpServers": {
    "postiz": {
      "url": "https://<domain>/mcp/<API-KEY>/sse"
    }
  }
}
```

Docs: [docs.postiz.com/public-api](https://docs.postiz.com/public-api/introduction)

## Limitations

- **Dedicated server** — 4-6 containers, ~3.5-4GB RAM
- **Slow start** — Temporal + Next.js take ~90-120s to boot
- **HTTPS required** — most OAuth providers require HTTPS for callback URLs
- **SSH tunnel without domain** — Postiz sets secure cookies; login over HTTP won't work. Add `NOT_SECURED=true` to docker-compose (dev/tunnel only!)

## Backup

Data in `/opt/stacks/postiz/`:
- `config/` — configuration
- `uploads/` — uploaded media
- `postgres-data/` — Postiz database
- `redis-data/` — Redis cache
- `temporal-postgres-data/` — Temporal database
- `.env` — social platform API keys
