# PostStack - Social Media Publishing, Inbox Automation & CRM

Self-hosted multi-channel social media management: publishing & scheduling, inbox auto-replies, drip sequences, and contact CRM across Facebook, Instagram, YouTube, Telegram, and Gmail. Source-available alternative to ManyChat / Buffer / Hootsuite, without vendor lock-in.

## Installation

```bash
./local/deploy.sh poststack --ssh=ALIAS --domain-type=cloudflare --domain=inbox.example.com
```

The installer generates all secrets itself and brings up the full stack — no questions asked.

> **HTTPS is required for Meta.** OAuth + webhooks only work over HTTPS, so deploy with `--domain-type=cloudflare` (or `caddy`). The app boots over plain HTTP too, but Meta channels won't connect until it's reachable over HTTPS.

## Requirements

- **RAM:** ~1.3GB (web 512M + worker 512M + postgres 256M + nginx 64M)
- **Disk:** ~600MB images + Postgres data volume
- **Port:** 3000 (the bundled nginx; bound to `127.0.0.1` behind Caddy/Cloudflare)
- **Database:** PostgreSQL 16 (bundled in compose, zero config)
- **Network:** access to GHCR (images are public — no login needed)

## Stack

| Component | Technology |
|-----------|------------|
| Reverse proxy | nginx (SSE-aware) |
| Web | Hono + `hono/html` SSR on Bun |
| Worker | graphile-worker on Bun |
| Database / Queue | PostgreSQL 16 (Drizzle ORM) |
| Auth | Custom JWT (jose) |
| Images | `ghcr.io/jurczykpawel/poststack` + `-worker` |

## What the installer sets for you

Auto-generated and written to `/opt/stacks/poststack/.env` (chmod 600):

- `POSTGRES_PASSWORD`, `ENCRYPTION_KEY`, `JWT_SECRET`, `CRON_SECRET`, `ALTCHA_HMAC_KEY`
- `APP_URL` (from `--domain`), `NODE_ENV=production`
- `TRUSTED_PROXY` — `cloudflare` for `--domain-type=cloudflare`, otherwise `proxy`

> `ENCRYPTION_KEY` encrypts stored OAuth tokens. **Never change it** after channels are connected — re-running the installer preserves the existing `.env`.

## After Installation

1. Open `APP_URL/register` and create the **first** account (= owner). Self-registration then stays closed.
2. Connect Meta (Facebook/Instagram) — set the keys in `.env` (or in the UI → Settings) and restart:

```bash
ssh ALIAS 'nano /opt/stacks/poststack/.env'
# META_APP_ID=...  META_APP_SECRET=...  META_WEBHOOK_VERIFY_TOKEN=...
ssh ALIAS 'cd /opt/stacks/poststack && docker compose restart web worker'
```

  Then set the webhook callback URL to `APP_URL/api/webhooks/meta` (with your verify token) in the Meta App Dashboard.

3. Optional: Google/YouTube/Gmail OAuth, S3-compatible media storage, and a PRO `LICENSE_KEY`.

## Update

```bash
./local/deploy.sh poststack --ssh=ALIAS --update
```

Pulls the latest images and recreates the stack. Pin a specific release by re-running with `IMAGE_TAG=v0.8.3`.

## Source

https://github.com/jurczykpawel/poststack
