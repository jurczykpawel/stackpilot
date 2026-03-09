# FileBrowser - Tiiny.host Killer

Private drive + public file hosting. A Tiiny.host replacement at a fraction of the cost.

## Installation

```bash
# With public static hosting
DOMAIN_PUBLIC=static.example.com ./local/deploy.sh filebrowser \
  --ssh=ALIAS \
  --domain-type=cloudflare \
  --domain=files.example.com \
  --yes

# Admin panel only (no public hosting)
./local/deploy.sh filebrowser --ssh=ALIAS --domain-type=local --yes
```

After installation you have:
- `https://files.example.com` — admin panel (login required)
- `https://static.example.com` — public files (no login, via Caddy)

### Adding public hosting later

If you installed without `DOMAIN_PUBLIC`, add it anytime:

```bash
./local/add-static-hosting.sh static.example.com ALIAS
```

## Requirements

- **RAM:** ~128MB (FileBrowser container limit)
- **Disk:** ~40MB (filebrowser/filebrowser image)
- **Port:** 8095 (default from `PORT=${PORT:-8095}`)
- **Database:** none (SQLite file `filebrowser.db`)

## After Installation

1. Open `https://files.example.com` (or SSH tunnel to port 8095)
2. Login: `admin` / `admin`
3. **Change the password immediately**
4. Upload files to `/var/www/public/` — they appear at `https://static.example.com`

## How It Works

```
files.example.com (ADMIN)
  -> FileBrowser on port 8095
  -> Upload, edit, delete files

static.example.com (PUBLIC)
  -> Caddy file_server -> /var/www/public/
  -> Direct access without login
  -> https://static.example.com/ebook.pdf
```

FileBrowser is the only Docker container. Caddy handles static hosting directly
as a `file_server` — no nginx container is created.

## Use Cases

- **Lead magnet:** upload PDF → link `https://static.example.com/ebook.pdf`
- **Landing page:** upload `index.html` → instant static site
- **Client proposals:** `proposal-client.pdf` → shareable link

## Management

```bash
# Logs
ssh ALIAS "docker logs -f filebrowser-filebrowser-1"

# Restart
ssh ALIAS "cd /opt/stacks/filebrowser && docker compose restart"

# Update
ssh ALIAS "cd /opt/stacks/filebrowser && docker compose pull && docker compose up -d"

# Status
ssh ALIAS "docker ps --filter name=filebrowser"
```

## Backup

Files are stored in `/var/www/public/` on the server.

```bash
./local/sync.sh down /var/www/public ./backup-files --ssh=ALIAS
```

## Troubleshooting

### File not visible on public site
```bash
ssh ALIAS "sudo chmod -R o+r /var/www/public/"
```

### 403 Forbidden
```bash
ssh ALIAS "sudo chown -R 1000:1000 /var/www/public/"
```
