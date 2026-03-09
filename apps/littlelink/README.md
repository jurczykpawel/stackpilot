# LittleLink - Link in Bio (Lightweight Version)

Extremely lightweight Linktree alternative. Pure HTML + CSS, zero database, zero Docker container.

## Installation

```bash
./local/deploy.sh littlelink --ssh=ALIAS --domain-type=cloudflare --domain=bio.example.com
# or with Caddy:
./local/deploy.sh littlelink --ssh=ALIAS --domain-type=caddy --domain=bio.example.com
```

A domain is required — the installer will exit with an error if `DOMAIN` is not set.

## Requirements

- **RAM:** ~0MB (no Docker container — Caddy serves static files directly)
- **Disk:** ~50MB (cloned HTML/CSS/JS files)
- **Database:** none
- **Port:** none (Caddy `file_server` mode, no application port)

## After Installation

LittleLink has no admin panel. Edit `index.html` directly.

**Workflow:**
1. Download files to your computer:
   ```bash
   ./local/sync.sh down /var/www/littlelink ./my-bio --ssh=ALIAS
   ```
2. Edit `index.html` in VS Code (add your links, avatar, colors)
3. Upload changes to the server:
   ```bash
   ./local/sync.sh up ./my-bio /var/www/littlelink --ssh=ALIAS
   ```

Or edit directly on the server:
```bash
ssh ALIAS "nano /var/www/littlelink/index.html"
```

## Backup

Files are stored in `/var/www/littlelink/` on the server. Sync down to back up:

```bash
./local/sync.sh down /var/www/littlelink ./my-bio-backup --ssh=ALIAS
```
