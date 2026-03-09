# FileBrowser - Tiiny.host Killer

Private drive + public file hosting. A Tiiny.host replacement at a fraction of the cost.

**RAM:** ~160MB (FileBrowser + Nginx) | **Disk:** depends on files | **Plan:** Mikrus 1.0 PRO+ (35 PLN/yr + 60 PLN one-time for Docker)

## Installation

### Full setup (admin + public hosting)

```bash
# Cloudflare domain
DOMAIN_PUBLIC=static.example.com ./local/deploy.sh filebrowser \
  --ssh=ALIAS \
  --domain-type=cloudflare \
  --domain=files.example.com \
  --yes
```

After installation you have:
- `https://files.example.com` — admin panel (login required)
- `https://static.example.com` — public files (no login)

### Admin panel only (no public hosting)

```bash
./local/deploy.sh filebrowser --ssh=ALIAS --domain-type=local --yes
```

Useful when you want a private drive only, or plan to add public hosting later.

### Adding public hosting later

If you installed without `DOMAIN_PUBLIC`, add it anytime:

```bash
./local/add-static-hosting.sh static.example.com ALIAS

# Custom directory
./local/add-static-hosting.sh cdn.example.com ALIAS /var/www/cdn

# Custom directory and port
./local/add-static-hosting.sh assets.example.com ALIAS /var/www/assets 8097
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
┌─────────────────────────────────────────────────────────────┐
│  files.example.com (ADMIN)                                  │
│  -> FileBrowser with login                                  │
│  -> Upload, edit, delete files                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ files in /var/www/public/
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  static.example.com (PUBLIC)                                │
│  -> Direct access without login                             │
│  -> https://static.example.com/ebook.pdf                    │
└─────────────────────────────────────────────────────────────┘
```

FileBrowser is the only Docker container. Caddy handles static hosting directly
as a `file_server` — no extra nginx container is needed.

## Use Cases

- **Lead magnet:** upload PDF → link `https://static.example.com/ebook.pdf` → use in automation (n8n, email)
- **Landing page:** upload `index.html` → instant static site at `https://static.example.com/`
- **Client proposals:** `proposal-smith.pdf` → shareable private-looking link

## Cost Comparison

| Solution | Price/year | Limit |
|---|---|---|
| Tiiny.host Pro | ~$120/yr | 10 sites |
| Tiiny.host Business | ~$300/yr | 50 sites |
| **FileBrowser + Mikrus 1.0 PRO** | **35 PLN/yr + 60 PLN one-time (Docker)** | **unlimited** |

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

## Security

**Change the password after first login!**
```
Default credentials: admin / admin
```

### File visibility
- **Admin** (`files.*`) — requires login
- **Public** (`static.*`) — accessible to anyone with the link

For "unlisted" files use random names: `proposal-x7k9m2.pdf`

## Troubleshooting

### File not visible on public site
```bash
ssh ALIAS "sudo chmod -R o+r /var/www/public/"
```

### 403 Forbidden
```bash
ssh ALIAS "sudo chown -R 1000:1000 /var/www/public/"
```
