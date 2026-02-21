# AGENTS.md

Instructions for AI agents (Claude Code, Cursor, Copilot, etc.) working with this repository.

## Project and Role

Bash scripts for managing self-hosted VPS servers.
The toolbox automates Docker application installation, domain configuration, backups, and diagnostics.

You help users manage their VPS servers. You can:
- Install applications (`./local/deploy.sh`)
- Configure backups and domains
- Host static sites (`./local/add-static-hosting.sh`) and PHP sites (`./local/add-php-hosting.sh`)
- Sync files with the server (`./local/sync.sh`)
- Diagnose problems (logs, ports, RAM)
- Create new app installers (`apps/<app>/install.sh`)

**Always communicate in English.** Do as much as you can for the user, explain the rest step by step.

**IMPORTANT:** Never manually construct API calls -- always use the provided scripts.

## Repository Structure

```
local/           -> User scripts (deploy, backup, setup)
apps/<app>/      -> App installers (install.sh + README.md)
lib/             -> Helper libraries (cli-parser, db-setup, domain-setup, server-exec, port-utils)
system/          -> System scripts (docker, caddy, backup-core)
docs/            -> Documentation (Cloudflare, CLI reference)
mcp-server/      -> MCP server for AI assistants (TypeScript)
```

## Dual-Mode Operation (local + on-server)

Scripts work **both from your computer** (via SSH) **and directly on the server**.
Detection: the presence of Docker and the server environment is auto-detected.

```bash
# From your computer (default):
./local/deploy.sh uptime-kuma --ssh=vps

# On the server (after installing toolbox):
ssh vps
deploy.sh uptime-kuma
```

Install the toolbox on the server: `./local/install-toolbox.sh [ssh_alias]`

The `lib/server-exec.sh` library provides transparent wrappers:
- `server_exec "cmd"` -> ssh or bash -c
- `server_copy src dst` -> scp or cp
- `server_hostname` -> ssh -G or hostname

Local-only scripts (do not run on the server): `setup-ssh.sh`, `sync.sh`

## Initial Server Setup

On a fresh server, install Docker if not already present:

```bash
ssh vps
# Install Docker:
curl -fsSL https://get.docker.com | sh
```

Check whether Docker is installed:
```bash
ssh vps 'docker --version'
```

## Domain Configuration

Three domain types are supported:

### 1. Cloudflare (own domain with CDN and proxy)

- Requires Cloudflare account and API token (`./local/setup-cloudflare.sh`)
- DNS record added via API (AAAA for IPv6, A for IPv4)
- Caddy as reverse proxy with auto-SSL on the server
- Best for production use

```bash
./local/dns-add.sh app.example.com vps
```

### 2. Caddy (direct domain, auto-HTTPS)

- Caddy runs on the server as a reverse proxy
- Automatic Let's Encrypt SSL certificates
- Domain DNS must point directly to your server IP

### 3. Local (SSH tunnel, no domain)

- No public domain; access via SSH tunnel only
- Best for admin panels and sensitive tools

```bash
ssh -L 5001:localhost:5001 vps
# Then open http://localhost:5001
```

**After `deploy_app` with a domain configured** -- domain is set up automatically, no extra steps needed.
**After `deploy_custom_app`** -- use `setup_domain` to assign a domain.

## Backup (MCP: `setup_backup`)

After deployment, backup status is checked. If no backup is configured, the agent receives a warning and should suggest setting one up.

Backup types:
- `setup_backup(backup_type='db')` -- automatic daily database backup (cron on server)
- `setup_backup(backup_type='cloud')` -- cloud backup (Google Drive, Dropbox, S3) -- requires running `./local/setup-backup.sh` locally (OAuth in browser)

The toolbox is automatically installed on the server (git clone from GitHub) if not already present.

## Deploy Applications

```bash
./local/deploy.sh APP [options]

# Options:
#   --ssh=ALIAS           SSH alias (default: vps)
#   --domain-type=TYPE    cloudflare | caddy | local
#   --domain=DOMAIN       Domain for the app
#   --db-source=SOURCE    bundled | custom (databases)
#   --yes, -y             Skip all confirmation prompts

# Examples:
./local/deploy.sh n8n --ssh=vps --domain-type=cloudflare --domain=n8n.example.com
./local/deploy.sh uptime-kuma --ssh=vps --domain-type=local --yes
./local/deploy.sh wordpress --ssh=vps --domain-type=caddy --domain=blog.example.com
```

**WordPress env vars** (passed as options or env):
- `WP_DB_MODE=sqlite|mysql` - database mode (default: mysql)
- `WP_REDIS=auto|external|bundled` - Redis auto-detection on host

**Post-install WordPress** -- `wp-init.sh` runs automatically during installation.
Only manual step: open the site in a browser for the WordPress setup wizard.

### GateFlow (flagship product)

Digital products sales platform (Gumroad/EasyCart alternative). Does not use Docker -- runs on Bun + PM2 (Next.js standalone).

**Requirements:** Supabase (free account), optionally Stripe (payments).

**MCP deployment** -- full flow without pasting secrets:
```
# Step 1: Agent calls setup_gateflow_config() -> opens browser for Supabase login
# Step 2: User provides one-time verification code (8 chars, NOT a secret)
# Step 3: Agent calls setup_gateflow_config(verification_code="ABCD1234") -> fetches projects
# Step 4: User picks a project -> agent calls setup_gateflow_config(project_ref="xxx")
#          -> keys fetched automatically and saved to ~/.config/stackpilot/gateflow/deploy-config.env
# Step 5: Agent calls deploy_app(app_name="gateflow") -> config loaded from file
```

**SECURITY:** Do NOT ask the user to paste keys (service_role, Stripe SK) into the conversation -- they would travel through the API. Use `setup_gateflow_config` -- secrets never enter the conversation.

**CLI deployment:**
```bash
# Interactive (guided setup)
./local/deploy.sh gateflow --ssh=vps --domain-type=cloudflare --domain=shop.example.com

# Automated (requires prior setup-gateflow-config.sh)
./local/deploy.sh gateflow --ssh=vps --yes
```

**After installation:**
- First registered user = admin
- Stripe webhooks: `https://DOMAIN/api/webhooks/stripe` (events: checkout.session.completed, payment_intent.succeeded)
- Turnstile CAPTCHA: optional, `./local/setup-turnstile.sh DOMAIN SSH_ALIAS`
- Multi-instance: each domain = separate directory (`/opt/stacks/gateflow-{subdomain}/`)

## File Sync (sync.sh)

```bash
./local/sync.sh up   <local_path> <remote_path> [--ssh=ALIAS]
./local/sync.sh down <remote_path> <local_path> [--ssh=ALIAS]

# Options:
#   --ssh=ALIAS    SSH alias (default: vps)
#   --dry-run      Show what would happen without executing

# Examples:
./local/sync.sh up ./my-website /var/www/html --ssh=vps
./local/sync.sh down /opt/stacks/n8n/.env ./backup/ --ssh=prod
./local/sync.sh up ./dist /var/www/public/app --dry-run
```

A simple rsync wrapper for quick file transfers without a full deploy.

## Hosting (Static and PHP)

### Static Hosting

```bash
./local/add-static-hosting.sh DOMAIN [SSH_ALIAS] [DIRECTORY]
```

### PHP Hosting

```bash
./local/add-php-hosting.sh DOMAIN [SSH_ALIAS] [DIRECTORY]

# Examples:
./local/add-php-hosting.sh app.example.com
./local/add-php-hosting.sh app.example.com vps /var/www/app
```

Deploys Caddy + PHP-FPM on the host. Auto-installs both if missing.

MCP: `deploy_site` with a PHP project (detects `index.php` or `.php` files).

## Applications (28)

All located in `apps/<name>/install.sh`. Run via `deploy.sh`, not directly.

n8n, ntfy, uptime-kuma, filebrowser, dockge, stirling-pdf, vaultwarden, linkstack, littlelink, nocodb, umami, listmonk, typebot, redis, wordpress, convertx, postiz, crawl4ai, cap, gateflow, minio, gotenberg, cookie-hub, mcp-docker, social-media-generator, coolify

Details for a specific app (ports, requirements, DB) -> `apps/<app>/README.md` or `GUIDE.md`

### Coolify (special flow)

Coolify is a full PaaS (private Heroku) -- **only for servers with 8GB+ RAM and 80GB+ disk**.
Does not use `DOMAIN_TYPE`, `DB_*`, or `/opt/stacks/`. Delegates to the official Coolify installer (`curl | bash`), which installs Docker, Traefik, PostgreSQL, Redis and creates `/data/coolify/`.
Takes over ports 80/443 -- **do not mix with other toolbox apps.**

## WordPress - Architecture

The most complex application. Custom Dockerfile, 3 containers, auto-tuning based on RAM.

```
wordpress (build: .) -> wordpress:php8.3-fpm-alpine + pecl redis + WP-CLI
nginx:alpine          -> gzip, FastCGI cache, rate limiting, security headers
redis:alpine          -> object cache (bundled or external, auto-detection)
```

**Server files (`/opt/stacks/wordpress/`):**
- `Dockerfile` - extends wordpress:fpm-alpine + redis ext + WP-CLI
- `docker-compose.yaml` - dynamic (depends on DB and Redis mode)
- `config/` - php-opcache.ini, php-performance.ini, www.conf, nginx.conf
- `wp-init.sh` - post-install: wp-config tuning + Redis Object Cache (WP-CLI)
- `flush-cache.sh` - clears FastCGI cache
- `.redis-host` - `redis` (bundled) or `host-gateway` (external)

**DB detection:** install.sh contains literals `DB_HOST` and `mysql`, so deploy.sh automatically detects MySQL requirement. In `WP_DB_MODE=sqlite` mode, DB variables are ignored.

**wp-init.sh automatically:** HTTPS fix, WP-Cron to system cron, revision limit, autosave 5min, DISALLOW_FILE_EDIT, Redis config + plugin install/activate via WP-CLI.

## Code Style

### Conventions

- `set -e` in every script
- Variables: `UPPER_CASE`, functions: `snake_case()` (no `function` keyword)
- Files: `kebab-case.sh`, directories: `kebab-case`
- Always set `memory:` limit in docker-compose
- Ports: `127.0.0.1:$PORT:CONTAINER_PORT` (for security; Cloudflare proxy mode may need `$PORT:CONTAINER_PORT` without 127.0.0.1 -- deploy.sh passes `DOMAIN_TYPE`)

### install.sh Pattern

```bash
#!/bin/bash

# StackPilot - Application Name
# Description.
# Author: Your Name
#
# IMAGE_SIZE_MB=200  # Docker image size

set -e

APP_NAME="myapp"
STACK_DIR="/opt/stacks/$APP_NAME"
PORT=${PORT:-3000}

# Validation (if DB required)
if [ -z "$DB_HOST" ]; then echo "Error: Missing DB credentials!"; exit 1; fi

sudo mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  myapp:
    image: myimage:latest
    restart: always
    ports:
      - "127.0.0.1:$PORT:8080"
    deploy:
      resources:
        limits:
          memory: 256M
EOF

sudo docker compose up -d
```

### Key Rules

- Do not ask about domains in install.sh -- deploy.sh handles that
- Files go in `/opt/stacks/<app>/`
- `|| { echo "Error: ..."; exit 1; }` for error handling
- `|| true` for optional commands
- Never log secrets
- Secrets in env vars, configuration in `~/.config/stackpilot/`

## More Information

Detailed documentation -> **`GUIDE.md`** (operational reference):
- SSH and connection setup
- Full app table with ports
- Detailed deploy.sh flow (step by step)
- Backup and restore (configuration, manual run, verification)
- Diagnostics and troubleshooting (logs, ports, common issues)
- Architecture (Cloudflare/Caddy domains, databases)
- Limits and constraints (RAM, disk, ports)

Other sources:
- `apps/<app>/README.md` - per-application details
- `docs/CLI-REFERENCE.md` - full CLI parameter reference
