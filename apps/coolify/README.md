# Coolify - Your Private Heroku/Vercel

Open-source PaaS (Platform as a Service) with 280+ apps to install with one click. Automatic SSL, backups, Git push deploy, monitoring.

**Requires a large VPS** - 8GB RAM, 80GB disk, 2x CPU recommended.

## What You Get

- **280+ apps** from the catalog (one-click deploy): WordPress, n8n, Nextcloud, Grafana, Gitea, Ghost, Jellyfin, Vaultwarden, Uptime Kuma, PostHog, Supabase, Minio, Ollama...
- **Automatic SSL** - Let's Encrypt for every app
- **Git push deploy** - connect a repo from GitHub/GitLab, push = deploy
- **Backups** - automatic to S3-compatible storage
- **Monitoring** - alerts on disk, CPU, RAM, deployment status
- **Web terminal** - SSH to containers from the browser
- **Multi-server** - manage multiple servers from one panel

## Why a Large VPS?

| Component | RAM |
|---|---|
| Coolify (Laravel app) | ~300-500 MB |
| PostgreSQL 15 (platform) | ~50-100 MB |
| Redis 7 (cache/queues) | ~10-30 MB |
| Soketi (WebSocket) | ~30-50 MB |
| Traefik (reverse proxy) | ~50-100 MB |
| **Total (platform)** | **~500-800 MB** |

On a 4GB/40GB VPS it would be tight - the platform consumes ~800 MB, leaving ~3 GB for apps, and disk (40 GB) fills up quickly with Docker images.

On an 8GB/80GB VPS - comfortable. ~7 GB for apps, 80 GB disk for images and data.

## Installation

```bash
./local/deploy.sh coolify --ssh=ALIAS
```

### With admin pre-configuration (more secure)

```bash
ROOT_USERNAME=admin ROOT_USER_EMAIL=admin@example.com ROOT_USER_PASSWORD=SecretPass123 \
  ./local/deploy.sh coolify --ssh=ALIAS
```

Skips the open registration screen - the admin account is ready immediately.

### Disabling auto-updates

```bash
AUTOUPDATE=false ./local/deploy.sh coolify --ssh=ALIAS
```

Does not require: `--domain-type`, `--domain`, database. Coolify manages those itself.

## After Installation

### 1. Create an Admin Account (IMMEDIATELY!)

Open `http://<server-IP>:8000` and register. **The first registered user = administrator.** Until you register, the panel is open to everyone!

### 2. Configure a Domain (optional)

In the Coolify panel: Settings -> General -> set Instance's Domain (e.g. `https://panel.your-domain.com`).

DNS: add an A record `panel.your-domain.com` -> server IP. Traefik will automatically provision SSL.

### 3. Deploy Your First App

Resources -> + New -> Service -> pick from catalog (e.g. WordPress) -> Deploy.

Coolify automatically:
- Pulls the Docker image
- Configures the database (if needed)
- Provisions SSL via Let's Encrypt
- Configures routing via Traefik

## Architecture

```
Internet -> Traefik (:80/:443) -> app1, app2, app3...
                                  |
Browser  -> Coolify UI (:8000) -> PostgreSQL, Redis (platform)
```

### Ports

| Port | Service |
|---|---|
| 8000 | Coolify Panel (UI) |
| 80 | Traefik HTTP (redirect to HTTPS) |
| 443 | Traefik HTTPS (SSL, routing to apps) |
| 6001 | Soketi WebSocket (internal) |

### Directories

| Path | Contents |
|---|---|
| `/data/coolify/source/` | docker-compose and .env for the platform |
| `/data/coolify/applications/` | data for installed apps |
| `/data/coolify/databases/` | app database data |
| `/data/coolify/backups/` | backups |
| `/data/coolify/proxy/` | Traefik configuration |
| `/data/coolify/ssh/keys/` | SSH keys (container<->host) |

## Important Notes

- **Coolify takes over the server.** Traefik on ports 80/443 manages all HTTP/HTTPS traffic. Do not install other apps alongside it via deploy.sh - there will be port conflicts.
- **One panel, all apps.** After installing Coolify, manage ALL apps through the panel (not through deploy.sh).
- **Auto-update.** Coolify updates itself automatically by default. Disable in `/data/coolify/source/.env`: `AUTOUPDATE=false`.
- **Platform backup.** Coolify has built-in backups for apps (to S3). For Coolify itself = back up `/data/coolify/`.

## Example Apps from the Catalog

| Category | Apps |
|---|---|
| AI | Ollama, Open WebUI, Flowise, Langflow, LibreChat, LobeChat |
| Automation | N8N, Activepieces, Trigger |
| CMS | WordPress, Ghost, Directus, Strapi, Drupal |
| Monitoring | Uptime Kuma, Grafana, Glances, PostHog, Plausible |
| Storage | Nextcloud, MinIO, Seafile |
| Dev | Gitea, Forgejo, GitLab, Supabase, Jupyter, Code Server |
| Security | Vaultwarden, Authentik, Pi-hole, WireGuard |
| Media | Jellyfin, Plex, Immich, Navidrome |
| Business | Odoo, Invoice Ninja, Cal.com, Chatwoot |

Full list (280+): [coolify.io/docs/services](https://coolify.io/docs/services/)

## Useful Commands

```bash
# Platform logs
cd /data/coolify/source && docker compose logs -f

# Restart platform
cd /data/coolify/source && docker compose restart

# Container status
cd /data/coolify/source && docker compose ps

# Manual update
cd /data/coolify/source && docker compose pull && docker compose up -d
```

## Limitations

- **Requires a dedicated server** - Coolify takes over ports 80/443, does not coexist with other toolbox apps
- **Platform consumes ~500-800 MB RAM** - overhead for the web panel and infrastructure
- **Disk** - each app is another Docker image (500 MB - 3 GB); on 80 GB you can fit ~10-15 apps
- **Beta** - Coolify v4 is in beta (stable, but regressions can happen during auto-update)
