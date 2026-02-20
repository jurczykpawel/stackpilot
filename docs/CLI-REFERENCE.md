# CLI Reference - StackPilot

Complete command-line interface documentation for StackPilot.

## Table of Contents

- [Overview](#overview)
- [Configuration Priority](#configuration-priority)
- [deploy.sh - Main Script](#deploysh---main-script)
- [Global Options](#global-options)
- [Database Configuration](#database-configuration)
- [Domain Configuration](#domain-configuration)
- [Operating Modes](#operating-modes)
- [Config File](#config-file)
- [Per-Application Environment Variables](#per-application-environment-variables)
- [Examples](#examples)

---

## Overview

StackPilot supports three operating modes:

1. **Interactive** - the script prompts for missing values
2. **Semi-automatic** - some values from CLI, rest interactively
3. **Fully automated** - all values from CLI + `--yes`

```bash
# Interactive
./local/deploy.sh uptime-kuma --ssh=vps

# Fully automated
./local/deploy.sh uptime-kuma --ssh=vps --domain-type=caddy --domain=status.example.com --yes
```

---

## Configuration Priority

Values are resolved in the following order (highest priority first):

```
1. CLI flags             --db-host=psql.example.com
2. Environment vars      DB_HOST=psql.example.com ./deploy.sh ...
3. Config file           ~/.config/stackpilot/defaults.sh
4. Interactive prompts   (only when --yes is not set)
```

---

## deploy.sh - Main Script

```bash
./local/deploy.sh APP [options]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `APP` | Application name (e.g. `n8n`, `uptime-kuma`) or path to a script |

### Examples

```bash
# By application name
./local/deploy.sh n8n

# By path
./local/deploy.sh apps/n8n/install.sh

# System script
./local/deploy.sh system/caddy-install.sh
```

---

## Global Options

### SSH

| Flag | Description | Default |
|------|-------------|---------|
| `--ssh=ALIAS` | SSH alias from `~/.ssh/config` | `vps` |

```bash
./local/deploy.sh n8n --ssh=vps
./local/deploy.sh n8n --ssh production
```

### Operating Modes

| Flag | Description |
|------|-------------|
| `--yes`, `-y` | Skip all confirmation prompts. All required parameters must be provided. |
| `--dry-run` | Show what would be done without actually executing. |
| `--help`, `-h` | Show help. |

---

## Database Configuration

Used by applications that require PostgreSQL (n8n, listmonk, umami, nocodb, typebot) or MySQL (wordpress, cap).

### Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--db-source=TYPE` | `bundled` (Docker container) or `custom` | prompt |
| `--db-host=HOST` | Database host | prompt |
| `--db-port=PORT` | Database port | `5432` |
| `--db-name=NAME` | Database name | prompt |
| `--db-schema=SCHEMA` | PostgreSQL schema | `public` |
| `--db-user=USER` | Database user | prompt |
| `--db-pass=PASS` | Database password | prompt |

### --db-source=bundled

Runs a PostgreSQL/MySQL container alongside the application. Credentials are generated automatically.

```bash
./local/deploy.sh nocodb --ssh=vps --db-source=bundled --domain-type=caddy --domain=nocodb.example.com --yes
```

### --db-source=custom

Manual database configuration with your own credentials.

```bash
./local/deploy.sh n8n --ssh=vps \
  --db-source=custom \
  --db-host=psql.example.com \
  --db-port=5432 \
  --db-name=n8n_db \
  --db-user=n8n_user \
  --db-pass=secretpassword \
  --domain-type=cloudflare \
  --domain=n8n.example.com \
  --yes
```

---

## Domain Configuration

### Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--domain=DOMAIN` | Application domain | prompt |
| `--domain-type=TYPE` | `cloudflare`, `caddy`, or `local` | prompt |

### --domain-type=cloudflare

Own domain managed via Cloudflare. DNS record added through Cloudflare API, Caddy serves as reverse proxy with auto-SSL on the server.

```bash
./local/deploy.sh uptime-kuma --ssh=vps --domain-type=cloudflare --domain=status.example.com --yes
```

### --domain-type=caddy

Direct domain with Caddy reverse proxy and automatic Let's Encrypt SSL. DNS must point directly to your server IP.

```bash
./local/deploy.sh n8n --ssh=vps \
  --domain-type=caddy \
  --domain=n8n.example.com \
  --yes
```

### --domain-type=local

No domain. Access via SSH tunnel only.

```bash
./local/deploy.sh dockge --ssh=vps --domain-type=local --yes
# Access: ssh -L 5001:localhost:5001 vps  then open http://localhost:5001
```

---

## Operating Modes

### Interactive Mode (default)

The script prompts for missing values.

```bash
./local/deploy.sh n8n --ssh=vps
# > Choose database source [bundled/custom]: _
# > Enter domain: _
```

### --yes Mode (automated)

Requires all values upfront. Missing values result in an error.

```bash
# OK - all values provided
./local/deploy.sh uptime-kuma --ssh=vps --domain-type=local --yes

# ERROR - missing required values
./local/deploy.sh n8n --ssh=vps --yes
# > Error: --db-source is required in --yes mode
```

### --dry-run Mode

Shows what would be done without executing.

```bash
./local/deploy.sh n8n --ssh=vps --dry-run
# [dry-run] Simulating execution:
#   scp apps/n8n/install.sh vps:/tmp/stackpilot-deploy-123.sh
#   ssh -t vps "export DB_HOST=... ; bash '/tmp/stackpilot-deploy-123.sh'"
```

---

## Config File

Default values can be saved in `~/.config/stackpilot/defaults.sh`:

```bash
# ~/.config/stackpilot/defaults.sh

export DEFAULT_SSH="vps"
export DEFAULT_DB_PORT="5432"
export DEFAULT_DB_SCHEMA="public"
export DEFAULT_DOMAIN_TYPE="cloudflare"
```

Available variables:

| Variable | Description |
|----------|-------------|
| `DEFAULT_SSH` | Default SSH alias |
| `DEFAULT_DB_PORT` | Default database port |
| `DEFAULT_DB_SCHEMA` | Default PostgreSQL schema |
| `DEFAULT_DOMAIN_TYPE` | Default domain type |

---

## Per-Application Environment Variables

Each application accepts environment variables. deploy.sh automatically passes them to the installer.

### Database Applications (PostgreSQL)

**n8n, listmonk, umami, nocodb, typebot**

```bash
DB_HOST=...     # Database host
DB_PORT=...     # Port (default 5432)
DB_NAME=...     # Database name
DB_USER=...     # User
DB_PASS=...     # Password
DB_SCHEMA=...   # Schema (default public)
DOMAIN=...      # Optional domain
```

### Redis

```bash
REDIS_PASS=...  # Password (auto-generated if empty)
```

### Vaultwarden

```bash
ADMIN_TOKEN=... # Admin token (auto-generated if empty)
DOMAIN=...      # Optional domain
```

### Cap (Loom alternative)

Requires MySQL + S3.

```bash
# Option 1: External MySQL
DB_HOST=mysql.example.com
DB_PORT=3306
DB_NAME=cap
DB_USER=capuser
DB_PASS=secret

# Option 2: Local MySQL
MYSQL_ROOT_PASS=rootsecret

# Option 1: External S3
S3_ENDPOINT=https://xxx.r2.cloudflarestorage.com
S3_PUBLIC_URL=https://cdn.example.com
S3_REGION=auto
S3_BUCKET=cap-videos
S3_ACCESS_KEY=xxx
S3_SECRET_KEY=yyy

# Option 2: Local MinIO
USE_LOCAL_MINIO=true

# Required
DOMAIN=cap.example.com
```

### GateFlow

GateFlow uses **Bun + PM2** (not Docker). Installation is **interactive** - the script guides you through Supabase and Stripe configuration.

```bash
# Interactive setup (recommended)
./local/deploy.sh gateflow --ssh=vps

# With Cloudflare domain
./local/deploy.sh gateflow --ssh=vps --domain-type=cloudflare --domain=shop.example.com

# With Caddy domain
./local/deploy.sh gateflow --ssh=vps --domain-type=caddy --domain=shop.example.com
```

Optional environment variables (to skip interactive prompts):

```bash
# Supabase (from dashboard > Settings > API)
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_ANON_KEY=eyJ...
SUPABASE_SERVICE_KEY=eyJ...

# Stripe (from dashboard.stripe.com/apikeys)
STRIPE_PK=pk_live_...
STRIPE_SK=sk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...  # optional, added after installation

# Domain
DOMAIN=shop.example.com
```

**Requirements:** VPS with 1GB+ RAM, Supabase account (free tier), Stripe account

### FileBrowser

```bash
DOMAIN=...         # Optional admin panel domain
DOMAIN_PUBLIC=...  # Optional public hosting domain
PORT=...           # FileBrowser port (default 8095)
PORT_PUBLIC=...    # Static hosting port (default 8096)
```

Installation examples:

```bash
# Cloudflare - full setup (admin + public)
DOMAIN_PUBLIC=static.example.com ./local/deploy.sh filebrowser \
  --ssh=vps --domain-type=cloudflare --domain=files.example.com --yes

# Admin only (no public hosting)
./local/deploy.sh filebrowser --ssh=vps --domain-type=caddy --domain=files.example.com --yes

# Add public hosting later
./local/add-static-hosting.sh static.example.com vps
```

### Typebot

```bash
# Database
DB_HOST=...
DB_PORT=...
DB_NAME=...
DB_USER=...
DB_PASS=...

# Domain (auto-generates builder.DOMAIN and DOMAIN)
DOMAIN=typebot.example.com
```

### Simple Applications (DOMAIN only)

**uptime-kuma, ntfy, dockge, stirling-pdf, linkstack, cookie-hub, littlelink**

```bash
DOMAIN=...  # Optional domain
```

---

## Examples

### Full CI/CD Automation

```bash
#!/bin/bash
# deploy-production.sh

./local/deploy.sh n8n \
  --ssh=production \
  --db-source=custom \
  --db-host=psql.production.internal \
  --db-port=5432 \
  --db-name=n8n_prod \
  --db-user=n8n \
  --db-pass="$N8N_DB_PASSWORD" \
  --domain-type=cloudflare \
  --domain=n8n.company.com \
  --yes
```

### Quick Deploy with Caddy

```bash
./local/deploy.sh uptime-kuma --ssh=vps --domain-type=caddy --domain=status.example.com --yes
```

### Deploy Without a Domain (SSH Tunnel)

```bash
./local/deploy.sh dockge --ssh=vps --domain-type=local --yes
# Access: ssh -L 5001:localhost:5001 vps
```

### Dry Run Before Production

```bash
./local/deploy.sh n8n \
  --ssh=production \
  --db-source=custom \
  --db-host=psql.example.com \
  --domain-type=cloudflare \
  --domain=n8n.company.com \
  --dry-run
```

### Deploy with Config File

```bash
# ~/.config/stackpilot/defaults.sh
export DEFAULT_SSH="vps"
export DEFAULT_DOMAIN_TYPE="cloudflare"

# Now just:
./local/deploy.sh uptime-kuma --domain=status.example.com --yes
```

---

## Platform Compatibility

StackPilot works on:

| System | Status | Notes |
|--------|--------|-------|
| macOS | Supported | Full support |
| Linux (Ubuntu, Debian, etc.) | Supported | Full support |
| Windows + WSL2 | Supported | Recommended for Windows |
| Windows + Git Bash | Partial | See below |

### Windows + Git Bash

Git Bash with the default MinTTY terminal has issues with interactive SSH sessions. The script automatically detects this environment and shows a warning.

**Solutions:**

1. **Windows Terminal (recommended)** - run Git Bash inside Windows Terminal
2. **winpty** - prefix for commands:
   ```bash
   winpty ./local/deploy.sh n8n --ssh=vps
   ```
3. **Automated mode** - use `--yes` to skip interactive prompts:
   ```bash
   ./local/deploy.sh uptime-kuma --ssh=vps --domain-type=local --yes
   ```
4. **WSL2 (best option)** - install Ubuntu from the Microsoft Store

**The `--yes` mode works without issues** on Git Bash since it requires no interactive prompts.

---

## Troubleshooting

### "Error: --db-source is required in --yes mode"

In `--yes` mode, all required values must be provided. Add the missing flag or remove `--yes` for interactive mode.

### Bundled DB issues

If the bundled PostgreSQL container fails to start, check logs with `docker compose logs db` inside the app's stack directory. Common causes: port conflict, insufficient disk space.

### Domain not working immediately

After configuring a domain, it may take up to 60 seconds before it starts responding. The script automatically waits for propagation.

### SSH connection refused

Check that the SSH alias is correctly configured in `~/.ssh/config`:

```
Host vps
    HostName 203.0.113.10
    User root
    Port 22
```
