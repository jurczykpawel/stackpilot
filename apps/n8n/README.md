# n8n - Your Automation Engine

**Alternative to Make.com / Zapier without operation limits.**
Connect apps, automate processes, build workflows visually.

> **Official site:** https://n8n.io

---

## Why n8n?

| | Zapier | Make | **n8n** |
|---|---|---|---|
| 100 tasks/mo | $0 | $0 | **$0** |
| 2,000 tasks/mo | ~$25/mo | ~$12/mo | **$0** |
| Unlimited | ~$100/mo | ~$35/mo | **$0** |

You only pay for hosting.

---

## Requirements

- **RAM:** 800MB (n8n container limit); bundled PostgreSQL adds ~256MB on top
- **Disk:** ~800MB image (n8nio/n8n:latest)
- **Port:** 5678 (default: `PORT=${PORT:-5678}`)
- **Database:** PostgreSQL with `pgcrypto` extension (required)

### PostgreSQL Options

> **The shared Mikrus database does NOT work!** n8n requires the `pgcrypto` extension (`gen_random_uuid()`), which is not available on shared PostgreSQL. You need a dedicated database.

**Option A — Bundled PostgreSQL 16 (dedicated container, easiest):**
```bash
./local/deploy.sh n8n --ssh=ALIAS --domain-type=cloudflare --domain=n8n.example.com --db-source=bundled
```
Starts a dedicated `postgres:16-alpine` container alongside n8n. No external DB needed.

**Option B — External/custom PostgreSQL:**
```bash
./local/deploy.sh n8n --ssh=ALIAS --domain-type=cloudflare --domain=n8n.example.com --db-source=custom
```
The script will ask for host, database, user, and password. A small 512MB/10GB managed instance is sufficient and can be shared between n8n, Listmonk, and Umami.

---

## Installation

```bash
# With bundled PostgreSQL (recommended for single-server setups):
./local/deploy.sh n8n --ssh=ALIAS --domain-type=cloudflare --domain=n8n.example.com --db-source=bundled

# With external PostgreSQL:
./local/deploy.sh n8n --ssh=ALIAS --domain-type=cloudflare --domain=n8n.example.com --db-source=custom

# Local access only (SSH tunnel):
./local/deploy.sh n8n --ssh=ALIAS --domain-type=local --db-source=bundled --yes
```

---

## After Installation

1. Open `https://n8n.example.com` (or `http://localhost:5678` via SSH tunnel)
2. Create your admin account on first launch — n8n will prompt you
3. Set up your first workflow

### SSH tunnel (local access):

```bash
ssh -L 5678:localhost:5678 ALIAS
# Then open http://localhost:5678
```

---

## Backup

n8n stores data in two places:

1. **Workflows and credentials** — in the PostgreSQL database
2. **Encryption key** — in `/opt/stacks/n8n/data/.n8n/` on the server

To back up:

```bash
# Copy the data directory (contains encryption key — required to restore credentials)
ssh ALIAS 'tar czf /tmp/n8n-data-backup.tar.gz /opt/stacks/n8n/data/'
scp ALIAS:/tmp/n8n-data-backup.tar.gz ./n8n-data-backup.tar.gz

# Also back up the database (if using bundled PostgreSQL):
ssh ALIAS 'cd /opt/stacks/n8n && docker compose exec db pg_dump -U n8n n8n > /tmp/n8n-db.sql'
scp ALIAS:/tmp/n8n-db.sql ./n8n-db.sql
```

> **Important:** Without the encryption key from the data directory, credential secrets cannot be decrypted even if you have a DB backup.

---

## Power Tools

n8n in a container does not have access to system tools (yt-dlp, ffmpeg).

To use them, in the **"Execute Command"** node enter:
```bash
ssh user@172.17.0.1 "yt-dlp https://youtube.com/..."
```

This connects from the container to the host, where tools are installed.

---

## Ecosystem Integration

n8n is the "brain" of your automation:

```
[Sellf - sales] --webhook--> [n8n]
[Typebot - chatbot]  --webhook-->  |
[Uptime Kuma - alert] -webhook-->  |
                                   v
              +--------------------+---------------------+
              v                    v                     v
      [NocoDB - CRM]       [Listmonk - mail]    [ntfy - push]
```

---

## FAQ

**Q: How much RAM does n8n use?**
A: 400-600MB at rest, more with complex workflows. The memory limit in docker-compose is set to 800MB.

**Q: Can I use SQLite instead of PostgreSQL?**
A: You can, but it is not recommended. SQLite locks up under many concurrent operations.

**Q: How to migrate workflows from Make/Zapier?**
A: Manually — n8n has different connectors. But most popular integrations (Slack, Google Sheets, Stripe) work similarly.
