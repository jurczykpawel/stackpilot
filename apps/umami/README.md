# Umami - Privacy-Friendly Analytics

Simple, fast and private alternative to Google Analytics. GDPR-compliant without annoying cookie banners.

> **Official site:** https://umami.is

---

## Why Umami?

- **You own your data:** Google does not sell your stats to advertisers.
- **Lightweight:** The tracking script weighs < 2KB. Your site loads faster.
- **Sharing:** You can generate a public stats link for your client.
- **No cookie banners required:** Umami does not use cookies or collect personal data.

---

## Requirements

- **RAM:** 256MB (limit set in docker-compose); bundled PostgreSQL adds ~256MB on top
- **Disk:** ~500MB image (ghcr.io/umami-software/umami:postgresql-latest — Next.js)
- **Port:** 3000 (default: `PORT=${PORT:-3000}`)
- **Database:** PostgreSQL with `pgcrypto` extension (required)

### PostgreSQL Options

> **The shared Mikrus database does NOT work!** The shared instance does not allow creating extensions like `pgcrypto`. You need a dedicated database.

> **`--db-source=bundled` works correctly.** It starts a dedicated `postgres:16-alpine` container which supports all required extensions.

**Option A — Bundled PostgreSQL 16 (dedicated container, easiest):**
```bash
./local/deploy.sh umami --ssh=ALIAS --domain-type=cloudflare --domain=stats.example.com --db-source=bundled
```
Starts a dedicated `postgres:16-alpine` container alongside Umami. No external DB needed.

**Option B — External/custom PostgreSQL:**
```bash
./local/deploy.sh umami --ssh=ALIAS --domain-type=cloudflare --domain=stats.example.com --db-source=custom
```
The script will ask for host, database, user, and password. A small 512MB/10GB managed instance is sufficient and can be shared between n8n, Listmonk, and Umami.

---

## Installation

```bash
# With bundled PostgreSQL (recommended):
./local/deploy.sh umami --ssh=ALIAS --domain-type=cloudflare --domain=stats.example.com --db-source=bundled

# With external PostgreSQL:
./local/deploy.sh umami --ssh=ALIAS --domain-type=cloudflare --domain=stats.example.com --db-source=custom

# Local access only (SSH tunnel):
./local/deploy.sh umami --ssh=ALIAS --domain-type=local --db-source=bundled --yes
```

---

## After Installation

1. Go to `https://stats.example.com`
2. Log in: **admin** / **umami**
3. **Change the password immediately!**
4. Go to **Settings → Websites → Add website** and add your site
5. Copy the tracking script and paste it into your website's `<head>`

### SSH tunnel (local access):

```bash
ssh -L 3000:localhost:3000 ALIAS
# Then open http://localhost:3000
```

---

## Backup

Data location: PostgreSQL database (no persistent files outside the DB)

Database backup (if using bundled PostgreSQL):
```bash
ssh ALIAS 'cd /opt/stacks/umami && docker compose exec db pg_dump -U umami umami > /tmp/umami-db.sql'
scp ALIAS:/tmp/umami-db.sql ./umami-db.sql
```
