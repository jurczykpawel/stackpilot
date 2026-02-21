# StackPilot - Operational Reference

> **Main instructions for AI -> [`AGENTS.md`](AGENTS.md)**. This document is a detailed reference -- consult it when you need specific commands, diagnostic procedures, or architecture details.

Complete technical documentation for StackPilot. Intended for AI agents and humans alike.

## Table of Contents

1. [Server Connection](#server-connection)
2. [Available Applications](#available-applications)
3. [Deployment Commands](#deployment-commands)
4. [Backup and Restore](#backup-and-restore)
5. [Diagnostics and Troubleshooting](#diagnostics-and-troubleshooting)
6. [Missing Tools](#missing-tools)
7. [Architecture](#architecture)
8. [Limits and Constraints](#limits-and-constraints)

---

## Server Connection

### SSH Alias

Servers are accessed via SSH. The alias is configured in `~/.ssh/config`:

```bash
# Check available aliases
grep "^Host " ~/.ssh/config

# Typical aliases: vps, production, staging, etc.
```

### Verifying the Connection

```bash
# Test connectivity
ssh vps 'echo "OK: $(hostname)"'

# Check server information
ssh vps 'hostname && cat /etc/os-release | head -2'
```

### Initial Server Setup

On a fresh VPS, ensure Docker is installed:

```bash
ssh vps
# Install Docker:
curl -fsSL https://get.docker.com | sh
```

Verify Docker installation:
```bash
ssh vps 'docker --version'
# If it fails: install Docker as shown above
```

### Running Scripts on the Server (Windows/PowerShell)

Windows users after SSH setup (`setup-ssh.ps1`) can run scripts directly on the server:

```bash
# 1. From your local machine - install toolbox on the server:
./local/install-toolbox.sh vps

# 2. Connect to the server:
ssh vps

# 3. Run scripts directly:
deploy.sh uptime-kuma
```

Environment detection: scripts automatically detect whether they are running on the server and skip SSH -- commands execute directly.

Local-only scripts (do not work on the server): `setup-ssh.sh`, `sync.sh`

---

## Available Applications

Applications are located in `apps/<name>/install.sh`:

| Application | Description | Database | Port |
|-------------|-------------|----------|------|
| **uptime-kuma** | Service monitoring (like UptimeRobot) | - | 3001 |
| **ntfy** | Push notifications | - | 8085 |
| **filebrowser** | Web file manager | - | 8095 |
| **dockge** | Docker Compose management UI | - | 5001 |
| **stirling-pdf** | Online PDF tools | - | 8087 |
| **n8n** | Workflow automation | PostgreSQL* | 5678 |
| **umami** | Web analytics (alt. Google Analytics) | PostgreSQL* | 3000 |
| **nocodb** | Database (alt. Airtable) | PostgreSQL | 8080 |
| **listmonk** | Newsletter and mailing | PostgreSQL* | 9000 |
| **typebot** | Chatbot builder | PostgreSQL* | 8081/8082 |
| **vaultwarden** | Password manager (Bitwarden) | SQLite | 8088 |
| **linkstack** | Link page (alt. Linktree) | SQLite | 8090 |
| **redis** | Cache / key-value store | - | 6379 |
| **wordpress** | CMS (Performance Edition: FPM+Nginx+Redis) | MySQL/SQLite | 8080 |
| **convertx** | File converter (100+ formats) | SQLite | 3000 |
| **postiz** | Social media scheduler | PostgreSQL* | 5000 |
| **crawl4ai** | Web crawler with AI extraction | - | 8000 |
| **cap** | Screen recording and sharing | MySQL | 3000 |
| **gateflow** | Digital product sales / launch page | PostgreSQL (Supabase) | 3333 |
| **minio** | Object storage (S3-compatible) | - | 9000 |
| **gotenberg** | Document conversion API (PDF) | - | 3000 |
| **cookie-hub** | Consent management (GDPR) | - | 8091 |
| **littlelink** | Link page (simpler alternative) | - | 8090 |
| **social-media-generator** | Social media graphics from templates | PostgreSQL | 8000 |
| **mcp-docker** | MCP server for Docker management | - | - |

*PostgreSQL with an asterisk requires `gen_random_uuid()` (PG 13+). Applies to: n8n, umami, listmonk, typebot, postiz. Use `bundled` or a dedicated database (PG 13+).

**WordPress** is a special application with its own Dockerfile (PHP redis ext + WP-CLI), bundled Redis, auto-tuning FPM based on RAM, and a post-install script `wp-init.sh`. Details: `apps/wordpress/README.md`.

---

## Deployment Commands

### All Local Scripts (`local/`)

| Script | Description | Usage |
|--------|-------------|-------|
| `deploy.sh` | Install applications | `./local/deploy.sh APP [options]` |
| `dns-add.sh` | Add Cloudflare DNS record | `./local/dns-add.sh DOMAIN [SSH]` |
| `add-static-hosting.sh` | Static file hosting | `./local/add-static-hosting.sh DOMAIN [SSH] [DIR] [PORT]` |
| `add-php-hosting.sh` | PHP site hosting | `./local/add-php-hosting.sh DOMAIN [SSH] [DIR]` |
| `setup-backup.sh` | Configure backups | `./local/setup-backup.sh [SSH]` |
| `restore.sh` | Restore from backup | `./local/restore.sh [SSH]` |
| `setup-cloudflare.sh` | Configure Cloudflare API | `./local/setup-cloudflare.sh` |
| `setup-turnstile.sh` | Configure Turnstile (CAPTCHA) | `./local/setup-turnstile.sh DOMAIN [SSH]` |
| `sync.sh` | File sync (rsync) | `./local/sync.sh up/down SRC DEST [--ssh=ALIAS]` |

---

### deploy.sh - Application Installation

```bash
./local/deploy.sh APP [options]

# Options:
#   --ssh=ALIAS           SSH alias (default: vps)
#   --domain-type=TYPE    cloudflare | caddy | local
#   --domain=DOMAIN       Domain for the app
#   --db-source=SOURCE    bundled | custom (databases)
#   --yes, -y             Skip all confirmation prompts
#   --dry-run             Show what would be done without executing

# Examples:
./local/deploy.sh n8n --ssh=vps --domain-type=cloudflare --domain=n8n.example.com
./local/deploy.sh uptime-kuma --ssh=vps --domain-type=local --yes
./local/deploy.sh gateflow --ssh=vps --domain-type=cloudflare --domain=gateflow.example.com
```

**deploy.sh flow:**
1. Confirms deployment
2. Asks about database (if required)
3. Asks about domain (Cloudflare/Caddy/local)
4. Performs resource checks (RAM, disk, ports)
5. Executes installation
6. Configures domain (after service is running)
7. Shows summary

---

### sync.sh - File Sync

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

A simple rsync wrapper for quick file transfers. Ideal for:
- Editing configuration locally (download -> edit -> upload)
- Uploading static sites to the server
- Backing up individual files

---

### dns-add.sh - Cloudflare DNS

```bash
./local/dns-add.sh <subdomain.domain.com> [ssh_alias] [mode]

# Requires: ./local/setup-cloudflare.sh (one-time setup)
# Examples:
./local/dns-add.sh app.example.com vps           # AAAA record (IPv6)
./local/dns-add.sh api.example.com vps ipv4       # A record (IPv4)
```

---

### add-static-hosting.sh - Static Hosting

```bash
./local/add-static-hosting.sh DOMAIN [SSH_ALIAS] [DIRECTORY] [PORT]

# Examples:
./local/add-static-hosting.sh static.example.com
./local/add-static-hosting.sh cdn.example.com vps /var/www/assets 8097
```

---

### add-php-hosting.sh - PHP Hosting

```bash
./local/add-php-hosting.sh DOMAIN [SSH_ALIAS] [DIRECTORY]

# Examples:
./local/add-php-hosting.sh app.example.com
./local/add-php-hosting.sh app.example.com vps /var/www/app
```

Deploys Caddy + PHP-FPM on the host. Auto-installs both if missing.

---

### System Scripts: `system/`

```bash
./local/deploy.sh system/docker-setup.sh   # Install Docker
./local/deploy.sh system/caddy-install.sh  # Install Caddy (reverse proxy)
./local/deploy.sh system/power-tools.sh    # CLI tools (yt-dlp, ffmpeg, pup)
./local/deploy.sh system/bun-setup.sh      # Install Bun + PM2
```

---

## Backup and Restore

### How Backup Works

All applications store data in `/opt/stacks/<app>/` using bind mounts.
The `backup-core.sh` script uses rclone to sync this directory to the cloud.

```
/opt/stacks/                          Cloud (Google Drive, Dropbox, etc.)
|-- uptime-kuma/data/          --->   vps-backup/stacks/uptime-kuma/data/
|-- ntfy/cache/                --->   vps-backup/stacks/ntfy/cache/
|-- vaultwarden/data/          --->   vps-backup/stacks/vaultwarden/data/
+-- ...
```

### Backup Configuration (one-time)

```bash
# Run the wizard - configures rclone and cron
./local/setup-backup.sh vps

# Wizard steps:
# 1. Choose provider (Google Drive, Dropbox, OneDrive, S3...)
# 2. Log in via browser (OAuth)
# 3. Optionally enable encryption
# 4. Done - cron will run backup daily at 3:00 AM
```

### Database Backup (automatic)

For apps using PostgreSQL or MySQL, an automatic daily database dump can be configured:

```bash
# Via MCP:
setup_backup(backup_type='db')

# Or manually on the server:
# The setup-db-backup.sh script auto-detects running database containers
# and sets up a cron job for daily dumps.
```

### Manual Backup / Verification

```bash
# Run backup now
ssh vps '~/backup-core.sh'

# Check logs
ssh vps 'tail -30 /var/log/stackpilot-backup.log'

# See what is in the cloud
ssh vps 'rclone ls backup_remote:vps-backup/stacks/'
```

### Restore

```bash
# Restore all data from the cloud
./local/restore.sh vps

# Or manually - restore a specific app
ssh vps 'rclone sync backup_remote:vps-backup/stacks/uptime-kuma /opt/stacks/uptime-kuma'
ssh vps 'cd /opt/stacks/uptime-kuma && docker compose up -d'
```

### Backup Verification

```bash
# Check if cron is set
ssh vps 'crontab -l | grep backup'

# Check last backup
ssh vps 'tail -10 /var/log/stackpilot-backup.log'

# Compare local vs cloud
ssh vps 'rclone check /opt/stacks backup_remote:vps-backup/stacks/'
```

---

## Diagnostics and Troubleshooting

### Container Status

```bash
# List running containers
ssh vps 'docker ps'

# Details with ports
ssh vps 'docker ps --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}"'

# All containers (including stopped)
ssh vps 'docker ps -a'
```

### Application Logs

```bash
# Logs for a specific app
ssh vps 'cd /opt/stacks/uptime-kuma && docker compose logs --tail 50'

# Follow logs in real time
ssh vps 'cd /opt/stacks/uptime-kuma && docker compose logs -f'

# Logs with timestamps
ssh vps 'cd /opt/stacks/uptime-kuma && docker compose logs --tail 50 -t'
```

### Local Testing

```bash
# Check if the app responds on its port
ssh vps 'curl -s localhost:3001 | head -5'

# Check HTTP headers
ssh vps 'curl -sI localhost:3001'

# Test from outside (via domain)
curl -sI https://status.example.com
```

### Common Problems and Solutions

#### 1. Container does not start

```bash
# Check logs
ssh vps 'cd /opt/stacks/<app> && docker compose logs --tail 100'

# Check if the image was pulled
ssh vps 'docker images | grep <app>'

# Restart the container
ssh vps 'cd /opt/stacks/<app> && docker compose restart'
```

#### 2. Cannot connect to the database

```bash
# Check if the database is reachable
ssh vps 'nc -zv <db_host> 5432'

# Test PostgreSQL connection
ssh vps 'PGPASSWORD=<pass> psql -h <host> -U <user> -d <db> -c "SELECT 1"'
```

#### 3. Domain not working (502/504)

- Check if the container is running: `docker ps`
- Check if the port is open: `curl localhost:PORT`
- Check if the port is NOT bound to 127.0.0.1 when using external domain access (must be 0.0.0.0 or no prefix)
- Verify DNS records point to the correct server IP
- Check Caddy status: `ssh vps 'systemctl status caddy'`

#### 4. Out of disk space

```bash
# Check disk usage
ssh vps 'df -h /'

# Clean unused Docker images
ssh vps 'docker system prune -af'

# Truncate container logs
ssh vps 'truncate -s 0 /var/lib/docker/containers/*/*-json.log'
```

#### 5. App works locally but not via domain

Ensure the port binding allows external access:
```yaml
# WRONG - localhost only
ports:
  - "127.0.0.1:3000:3000"

# CORRECT - all interfaces (needed for external reverse proxy)
ports:
  - "3000:3000"
```

For Caddy reverse proxy, 127.0.0.1 binding is fine since Caddy runs on the same server.

### Restarting Applications

```bash
# Restart
ssh vps 'cd /opt/stacks/<app> && docker compose restart'

# Full restart (down + up)
ssh vps 'cd /opt/stacks/<app> && docker compose down && docker compose up -d'

# Restart with new image
ssh vps 'cd /opt/stacks/<app> && docker compose pull && docker compose up -d'
```

### Removing Applications

```bash
# Stop and remove containers (keep data)
ssh vps 'cd /opt/stacks/<app> && docker compose down'

# Stop, remove containers and data (volumes)
ssh vps 'cd /opt/stacks/<app> && docker compose down -v'

# Remove completely (containers + files)
ssh vps 'cd /opt/stacks/<app> && docker compose down -v && rm -rf /opt/stacks/<app>'
```

---

## Missing Tools

### What is Available on a Typical VPS

Commonly pre-installed:
- `docker`, `docker compose` (after docker-setup.sh)
- `curl`, `wget`
- `git`
- `nano`, `vim`
- `htop`, `ncdu`

### Installing Missing Tools

```bash
# Update packages (Debian/Ubuntu)
ssh vps 'apt update && apt install -y <package>'

# Examples:
ssh vps 'apt install -y jq'      # JSON processor
ssh vps 'apt install -y tree'    # Directory tree viewer
ssh vps 'apt install -y ncdu'    # Disk usage analyzer
```

### Power Tools (optional)

The `system/power-tools.sh` script installs:
- `yt-dlp` - video downloading
- `ffmpeg` - media conversion
- `pup` - HTML parsing

```bash
./local/deploy.sh system/power-tools.sh
```

---

## Architecture

### Server Directory Structure

```
/opt/stacks/           # Docker Compose applications
  |-- uptime-kuma/
  |   |-- docker-compose.yaml
  |   +-- data/        # Application data (volumes)
  |-- n8n/
  +-- ...
```

### Two Ways to Get HTTPS Domains

#### 1. Cloudflare + Caddy (recommended for production)

- Requires Cloudflare account and API token
- DNS record (AAAA/A) pointing through Cloudflare proxy
- Caddy as reverse proxy with auto-SSL on the server
- Benefits: CDN, DDoS protection, IPv4-to-IPv6 translation

```bash
./local/setup-cloudflare.sh           # One-time: configure API token
./local/dns-add.sh app.example.com vps  # Add DNS record
```

#### 2. Caddy Direct (own domain, no Cloudflare)

- Point DNS directly to server IP
- Caddy handles Let's Encrypt certificates automatically
- Simpler setup, no third-party dependency

### Databases

#### Bundled Database (Docker container)

- PostgreSQL or MySQL runs as a container alongside the app
- Credentials auto-generated by deploy.sh
- Data stored in `/opt/stacks/<app>/` (backed up with the app)
- Best for simplicity

#### Custom Database (external)

- Provide your own database host, credentials, etc.
- Useful for managed database services or shared databases
- Full control over the database instance

---

## Limits and Constraints

### Server Resources

- RAM: varies by VPS plan (512MB - 8GB+)
- Disk: varies by VPS plan (10GB - 80GB+)
- **Always set memory limits in docker-compose.yaml!**

```yaml
deploy:
  resources:
    limits:
      memory: 256M
```

### Recommended Memory Limits

| Application | RAM Limit |
|-------------|-----------|
| uptime-kuma | 256M |
| ntfy | 128M |
| n8n | 512-768M |
| nocodb | 512M |
| vaultwarden | 128M |

### Ports

- Ports 80 and 443 are used by Caddy (reverse proxy)
- Use ports > 1024 for applications
- Avoid conflicts - check `docker ps` before installing

---

## Session Examples

### Installing a New Application

```bash
# 1. Check Docker is installed
ssh vps 'docker --version' || ssh vps 'curl -fsSL https://get.docker.com | sh'

# 2. Install the application
./local/deploy.sh uptime-kuma --ssh=vps

# 3. Verify
ssh vps 'docker ps | grep uptime'
curl -sI https://status.example.com
```

### Debugging a Broken Application

```bash
# 1. Check status
ssh vps 'docker ps -a | grep <app>'

# 2. Check logs
ssh vps 'cd /opt/stacks/<app> && docker compose logs --tail 50'

# 3. Test locally
ssh vps 'curl -s localhost:<port> | head -10'

# 4. Restart if needed
ssh vps 'cd /opt/stacks/<app> && docker compose restart'
```

### Updating an Application

```bash
# Pull new image and restart
ssh vps 'cd /opt/stacks/<app> && docker compose pull && docker compose up -d'

# Clean old images
ssh vps 'docker image prune -f'
```
