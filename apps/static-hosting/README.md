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

## Redirects

Add path-level redirects to a hosted domain (lead-magnet links, vanity URLs, product slugs):

```bash
./local/add-redirect.sh DOMAIN PATH TARGET [SSH_ALIAS] [--code=301|302]
./local/remove-redirect.sh DOMAIN PATH [SSH_ALIAS]

# Examples:
./local/add-redirect.sh techskills.academy /protocol-autonomy https://sellf.techskills.academy/some-product mikrus
./local/add-redirect.sh example.com /old https://new.example.com vps --code=302
```

Idempotent: re-running with the same `DOMAIN + PATH` swaps the target — handy when a campaign or product slug changes. The redirect lands inside the existing Caddy site block so it inherits TLS settings.

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

Pricing as of May 2026. Verify current prices on the providers' websites — vendors change plan structures regularly (Netlify dropped per-seat billing in April 2026, Tiiny.host reorganized plans in early 2026).

| Solution | Price/year | Sites |
|---|---|---|
| Vercel Pro | ~$240/yr ($20/mo annual) | "unlimited" (bandwidth + compute limits, overage applies) |
| Netlify Pro | ~$240/yr ($20/mo, credit-based) | "unlimited" (3,000 credits/mo, overage applies) |
| GitHub Pages | free | 1 per repo (public only) |
| Tiiny.host Tiny | ~$60/yr ($5/mo annual) | 1 site |
| Tiiny.host Solo | ~$118/yr ($18/mo, popular) | few sites |
| Tiiny.host Pro | ~$372/yr ($31/mo annual) | many sites |
| **Static Hosting + Mikrus 1.0** | **35 PLN/yr (~$9)** | **unlimited** |

**Thousands of static sites for 35 PLN/year.** The only limit is disk space (5GB on Mikrus 1.0, easily expandable).

Sources: [vercel.com/pricing](https://vercel.com/pricing), [netlify.com/pricing](https://www.netlify.com/pricing/), [tiiny.host/pricing](https://tiiny.host/pricing).

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
