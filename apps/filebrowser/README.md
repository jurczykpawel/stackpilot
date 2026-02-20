# FileBrowser - Tiiny.host Killer

Private drive + public file hosting. A Tiiny.host replacement at a fraction of the cost.

**RAM:** ~160MB (FileBrowser + nginx) | **Disk:** depends on files | **Plan:** 1GB+ RAM VPS

---

## Quick Start (one command)

### Caddy - full setup

```bash
DOMAIN_PUBLIC=static.your-domain.com ./local/deploy.sh filebrowser \
  --ssh=ALIAS \
  --domain-type=caddy \
  --domain=files.your-domain.com \
  --yes
```

### Cloudflare - full setup

```bash
DOMAIN_PUBLIC=static.example.com ./local/deploy.sh filebrowser \
  --ssh=ALIAS \
  --domain-type=cloudflare \
  --domain=files.example.com \
  --yes
```

After installation you have:
- `https://files.your-domain.com` - admin panel (login required)
- `https://static.your-domain.com` - public files (no login)

---

## Installation Scenarios

### 1. Full setup (admin + public)

```bash
# Caddy
DOMAIN_PUBLIC=static.your-domain.com ./local/deploy.sh filebrowser \
  --ssh=ALIAS --domain-type=caddy --domain=files.your-domain.com --yes

# Cloudflare
DOMAIN_PUBLIC=static.example.com ./local/deploy.sh filebrowser \
  --ssh=ALIAS --domain-type=cloudflare --domain=files.example.com --yes
```

### 2. Admin only (no public hosting)

```bash
./local/deploy.sh filebrowser --ssh=ALIAS
```

Useful when:
- You only want a private drive
- You will add public hosting later
- Testing before production

### 3. Adding public hosting later

If you installed without DOMAIN_PUBLIC, you can add it with one command:

```bash
# Caddy
./local/add-static-hosting.sh static.your-domain.com ALIAS

# Cloudflare
./local/add-static-hosting.sh static.example.com ALIAS
```

The script automatically:
- Starts nginx for Caddy or configures Caddy for Cloudflare
- Registers the domain
- Configures the /var/www/public directory

**Options:**
```bash
./local/add-static-hosting.sh DOMAIN [SSH_ALIAS] [DIRECTORY] [PORT]

# Examples:
./local/add-static-hosting.sh static.your-domain.com                          # defaults
./local/add-static-hosting.sh cdn.your-domain.com ALIAS /var/www/cdn          # custom directory
./local/add-static-hosting.sh assets.your-domain.com ALIAS /var/www/assets 8097  # custom port
```

---

## How It Works

```
+-------------------------------------------------------------+
|  files.example.com (ADMIN)                                   |
|  -> FileBrowser with login                                   |
|  -> Upload, edit, delete files                               |
+-------------------------------------------------------------+
                              |
                              | files in /var/www/public/
                              v
+-------------------------------------------------------------+
|  static.example.com (PUBLIC)                                 |
|  -> Direct access without login                              |
|  -> https://static.example.com/ebook.pdf                     |
+-------------------------------------------------------------+
```

---

## Use Cases

### Lead Magnet
```
1. Upload PDF via FileBrowser
2. Link: https://static.example.com/ebook.pdf
3. Use in automation (n8n, Mailchimp)
```

### Landing Page
```
1. Create index.html
2. Upload via FileBrowser
3. Done: https://static.example.com/
```

### Client Proposals
```
1. Upload: proposal-client.pdf
2. Send: https://static.example.com/proposal-client.pdf
```

---

## Architecture

### Caddy
- FileBrowser -> port 8095 -> Caddy reverse proxy
- nginx:alpine -> port 8096 -> Caddy reverse proxy

### Cloudflare
- FileBrowser -> port 8095 -> Caddy reverse_proxy
- Caddy file_server -> /var/www/public (no additional port)

---

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

---

## Security

**Change the password after first login!**
```
Default: admin / admin
```

### File Privacy
- **Admin** (`files.*`) - requires login
- **Public** (`static.*`) - accessible to everyone

For "hidden" links use random names: `proposal-x7k9m2.pdf`

---

## Troubleshooting

### File not visible on public
```bash
ssh ALIAS "sudo chmod -R o+r /var/www/public/"
```

### 403 Forbidden
```bash
ssh ALIAS "sudo chown -R 1000:1000 /var/www/public/"
```

### Domain placeholder (3-5 min)
Wait for propagation or check:
```bash
ssh ALIAS "curl -s localhost:8096/file.txt"
```

### nginx not starting
```bash
ssh ALIAS "docker logs filebrowser-static-1"
```
