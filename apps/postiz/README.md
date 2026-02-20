# Postiz - Social Media Post Scheduling

Alternative to Buffer/Hootsuite. Schedule posts on Twitter/X, LinkedIn, Instagram, Facebook, TikTok and more.

## Installation

```bash
./local/deploy.sh postiz --ssh=ALIAS --domain-type=caddy --domain=auto
```

deploy.sh will automatically configure the PostgreSQL database (dedicated required).

## Requirements

- **RAM:** recommended 2GB VPS, ~1-1.5GB usage (Postiz + Redis)
- **Disk:** ~3GB (Docker image)
- **Database:** PostgreSQL (dedicated -- bundled shared DB does not work, PG 12 lacks `gen_random_uuid()`)
- **Redis:** Auto-detection of external or bundled (see below)

## Version

We pin **v2.11.3** (pre-Temporal). From v2.12+, Postiz requires Temporal + Elasticsearch + a second PostgreSQL = 7 containers, minimum 4GB RAM. Too heavy for a small VPS.

## After Installation

1. Open the page in a browser and create an admin account
2. **Disable registration** after creating your account:
   ```bash
   ssh ALIAS 'cd /opt/stacks/postiz && grep -q DISABLE_REGISTRATION docker-compose.yaml || sed -i "/IS_GENERAL/a\      - DISABLE_REGISTRATION=true" docker-compose.yaml && docker compose up -d'
   ```
3. Connect social media accounts (Settings -> Integrations)
4. Schedule your first posts

## Environment Variables

install.sh sets these automatically:

| Variable | Description |
|----------|-------------|
| `MAIN_URL` | Main application URL |
| `FRONTEND_URL` | Frontend URL |
| `NEXT_PUBLIC_BACKEND_URL` | Public backend API URL |
| `DATABASE_URL` | PostgreSQL connection string |
| `REDIS_URL` | Redis connection string |
| `JWT_SECRET` | JWT secret (generated automatically) |
| `IS_GENERAL` | General mode (true) |
| `STORAGE_PROVIDER` | local (files on disk) |

Additional (add manually to docker-compose for integrations):

| Variable | Description |
|----------|-------------|
| `X_API_KEY`, `X_API_SECRET` | Twitter/X API |
| `LINKEDIN_CLIENT_ID`, `LINKEDIN_CLIENT_SECRET` | LinkedIn |
| `FACEBOOK_APP_ID`, `FACEBOOK_APP_SECRET` | Facebook/Instagram |
| `OPENAI_API_KEY` | AI post content generation |
| `DISABLE_REGISTRATION` | Disable registration (true after setup) |

Full list: [docs.postiz.com/configuration/reference](https://docs.postiz.com/configuration/reference)

## Supported Platforms

Twitter/X, LinkedIn, Instagram, Facebook, TikTok, YouTube, Pinterest, Reddit, Mastodon, Bluesky, Threads, Discord, Slack, Telegram and more (20+).

Each platform requires its own API keys - configure in Settings -> Integrations.

### Redis (external vs bundled)

By default, auto-detection: if port 6379 is listening on the server, Postiz connects to the existing Redis. Otherwise it bundles `redis:7.2-alpine`.

```bash
# Force bundled Redis (even when external exists)
POSTIZ_REDIS=bundled ./local/deploy.sh postiz --ssh=ALIAS

# Force external Redis (host)
POSTIZ_REDIS=external ./local/deploy.sh postiz --ssh=ALIAS

# External Redis with password
REDIS_PASS=secretPassword POSTIZ_REDIS=external ./local/deploy.sh postiz --ssh=ALIAS
```

## Limitations

- **Pinned version** - v2.11.3 (newer versions require Temporal, too heavy for small VPS)
- **Slow start** - Next.js starts in ~60-90s
- **OAuth requires HTTPS** - most platforms require HTTPS for callback URLs
- **SSH tunnel without domain** - Postiz sets secure cookies, login via HTTP will not work. Add `NOT_SECURED=true` to docker-compose (dev/tunnel only!)
- **Large image** - ~3GB on disk

## Backup

```bash
./local/setup-backup.sh ALIAS
```

Data in `/opt/stacks/postiz/`:
- `config/` - configuration (.env)
- `uploads/` - uploaded files
- `redis-data/` - Redis cache
- PostgreSQL database - backup via pg_dump
