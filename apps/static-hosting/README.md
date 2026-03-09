# Static Hosting

Host unlimited static websites on your own VPS. No per-site fees, no limits.

**RAM:** ~0MB extra (uses Caddy already running on the server) | **Disk:** depends on files | **Plan:** Mikrus 1.0+ (35 PLN/year)

## Quick Start

```bash
# Files already on the server
./local/add-static-hosting.sh mysite.example.com vps

# Upload local directory and serve it
./local/add-static-hosting.sh mysite.example.com vps ./dist

# Upload to a custom remote path
./local/add-static-hosting.sh mysite.example.com vps ./dist /var/www/mysite
```

That's it. The script:
1. Creates the remote directory
2. Uploads your files (if `LOCAL_DIR` provided)
3. Installs Caddy if not already present
4. Adds DNS record via Cloudflare (if configured)
5. Configures Caddy `file_server` for the domain with auto-HTTPS

## Parameters

```
./local/add-static-hosting.sh DOMAIN [SSH_ALIAS] [LOCAL_DIR] [REMOTE_DIR]
```

| Parameter | Default | Description |
|---|---|---|
| `DOMAIN` | required | Domain to serve (e.g. `blog.example.com`) |
| `SSH_ALIAS` | `vps` | SSH alias from `~/.ssh/config` |
| `LOCAL_DIR` | — | Local directory to upload (omit if files already on server) |
| `REMOTE_DIR` | `/var/www/DOMAIN` | Remote path to serve files from |

## Multiple Sites on One Server

Each domain is independent — add as many as disk space allows:

```bash
./local/add-static-hosting.sh blog.example.com vps ./blog-dist
./local/add-static-hosting.sh docs.example.com vps ./docs-dist
./local/add-static-hosting.sh landing.example.com vps ./landing-dist
./local/add-static-hosting.sh cdn.example.com vps ./assets /var/www/cdn
```

Each site gets its own directory under `/var/www/` and its own Caddy block with auto-HTTPS. No extra RAM per site — Caddy handles all of them from a single process.

## Updating Files

Re-run the same command — rsync uploads only changed files:

```bash
./local/add-static-hosting.sh mysite.example.com vps ./dist
```

Or sync manually:

```bash
./local/sync.sh up ./dist /var/www/mysite.example.com --ssh=vps
```

## Cost Comparison

| Solution | Price/year | Sites |
|---|---|---|
| Netlify Pro | $228/yr | unlimited (but bandwidth limits) |
| Vercel Pro | $240/yr | unlimited (but bandwidth limits) |
| GitHub Pages | free | 1 per repo (public only) |
| Tiiny.host Pro | ~$120/yr | 10 sites |
| Tiiny.host Business | ~$300/yr | 50 sites |
| **Static Hosting + Mikrus 1.0** | **35 PLN/yr (~$9)** | **unlimited** |

**Thousands of static sites for 35 PLN/year.** The only limit is disk space (5GB on Mikrus 1.0, easily expandable).

## Use Cases

- **Landing pages** — one-page sites for products, events, campaigns
- **Documentation** — export from Docusaurus, MkDocs, Astro, etc.
- **Client sites** — deliver static HTML/CSS sites to clients, host them yourself
- **Portfolio** — personal or project showcase
- **CDN for assets** — images, fonts, JS bundles served from your own domain
- **Lead magnets** — PDFs, templates, downloadable files
- **Staging environments** — deploy previews for review before going live

## What Gets Deployed

A `file_server` block in Caddy — the simplest possible web server:

```
mysite.example.com {
    root * /var/www/mysite.example.com
    file_server
    encode gzip
}
```

- Auto-HTTPS via Let's Encrypt (handled by Caddy)
- Gzip compression
- Serves `index.html` for directory requests
- No PHP, no database, no Docker container

## Requirements

- Caddy installed on the server (auto-installed by the script if missing)
- Domain DNS pointing to the server IP (or Cloudflare configured for auto DNS)
- No Docker required — runs on bare Mikrus 1.0 (35 PLN/yr, no PRO needed)

## Disk Space on Mikrus 1.0

Mikrus 1.0 has 5GB disk. Static sites are tiny:

| Site type | Typical size | How many fit |
|---|---|---|
| Landing page (HTML + CSS + images) | ~1-5MB | 600-3,000 |
| Documentation site | ~10-50MB | 60-300 |
| Portfolio with images | ~50-200MB | 15-60 |
| Blog (no images) | ~1-10MB | 300-3,000 |

Even running WordPress alongside, you still have ~1.4GB free for static sites.

## Troubleshooting

### File not found / 404
Check the remote directory contains the files:
```bash
ssh vps "ls /var/www/mysite.example.com/"
```

### Permission denied
```bash
ssh vps "sudo chmod -R o+rX /var/www/mysite.example.com/"
```

### HTTPS not working
Caddy auto-issues Let's Encrypt certificates. DNS must point to the server before running the script. Check:
```bash
ssh vps "sudo journalctl -u caddy -n 50"
```
