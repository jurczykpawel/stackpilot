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

## Why this installer vs Mikrus `n8n_install` / `n8n_install_postgres`?

Mikrus ships two built-in installers: `n8n_install` (SQLite) and `n8n_install_postgres` (bundled pgvector container). Both work for a quick demo on a `*.mikrus.cloud` subdomain, but they cut corners that hurt once people depend on your workflows. Here's what changes with `./local/deploy.sh n8n`:

| | `n8n_install` | `n8n_install_postgres` | **StackPilot** |
|---|---|---|---|
| Database | SQLite (single-writer, locks under load) | bundled `pgvector/pgvector:pg15` | bundled `postgres:16-alpine` **or** any external Postgres |
| pgvector / extensions | n/a | ✅ pgvector pre-installed (handy for AI workflows) | ❌ plain PG 16 (add manually if needed) |
| DB credentials | n/a | hardcoded `POSTGRES_USER=n8n` / `POSTGRES_PASSWORD=n8n` | random 24-char password (`openssl rand`) |
| Memory | `available - 100M` (greedy, no upper bound) | `available - 100M` (greedy, no upper bound) | hard caps: n8n 800M, db 256M |
| Updates | Watchtower auto-pulls every 3 days | Watchtower auto-pulls every 3 days | explicit `./update.sh` (you decide when) |
| HTTPS / domain | `*.mikrus.cloud` auto, custom domain only sets `WEBHOOK_URL` (no proxy/HTTPS) | same as left | your own domain via Caddy+Let's Encrypt or Cloudflare, full reverse proxy |
| Runtime | one long `docker run …` line | two `docker run` lines + manual `docker network create` | declarative `docker-compose.yaml` (n8n + db together) |
| Port exposure | `-p PORT:5678` on all interfaces | `-p PORT:5678` on all interfaces | `127.0.0.1:PORT` + reverse proxy |
| Provider | Mikrus only (calls `info.mikr.us`) | Mikrus only | any VPS (Hetzner, generic, Mikrus, …) |
| Multi-instance | single global `~/.n8n` | single global `~/.n8n` + `~/.pg_n8n` | per-install in `/opt/stacks/n8n/` |
| Backup | `/bin/n8n_backup` daily cron — `pg_dump`/`sqlite .backup` only; **encryption key in `~/.n8n/config` is NOT included** | same as left | logical: `n8n export:workflow` + `n8n export:credentials --encrypted` + `docker-compose.yaml` with `N8N_ENCRYPTION_KEY` → full restore possible on a fresh host |
| Recovery | encryption key path undocumented; without it, exported credentials are useless | same as left | encryption key location + restore steps documented |
| Min RAM | 1 GB (script's own check) | 2 GB (script's own check) | ~1.5 GB recommended for bundled (800M cap + 256M db + OS/Docker overhead); confirmed: 1 GB Mikrus OOMs under load |

> **Why no `--db-source=shared` for n8n on Mikrus?** StackPilot does support Mikrus's free shared databases for many apps — credentials are fetched automatically via the Mikrus API (`api.mikr.us/db.bash`) and there's a `--db-source=shared` flag wired up for postgres, mysql, and mongo (`lib/providers/mikrus/shared-db.sh`). For n8n it's deliberately blacklisted (see `lib/providers/mikrus/hooks.sh`, alongside `umami` and `listmonk`), and the test on Mikrus confirms the blacklist is correct: the shared instance is **PostgreSQL 12.6**, n8n's recent migrations call `gen_random_uuid()` (core in PG ≥13, otherwise needs `pgcrypto`), and `CREATE EXTENSION pgcrypto` returns `permission denied … must be superuser` for shared-DB users. There is no user-side workaround. On Mikrus it's bundled or custom Postgres only.

**TL;DR:** Mikrus's installers are "fastest path to a running container." StackPilot is "the install you'd want on any VPS, once your workflows actually matter."

---

## Requirements

- **RAM:** ~1.5 GB recommended for bundled mode (n8n 800M cap + db 256M cap + OS/Docker overhead). 1 GB hosts will OOM under migration/load. External-db mode needs ~1 GB.
- **Disk:** ~800MB image (n8nio/n8n:latest)
- **Port:** 5678 (default: `PORT=${PORT:-5678}`)
- **Database:** PostgreSQL ≥13 (recent n8n migrations call `gen_random_uuid()`, built-in since PG 13). Bundled mode uses `postgres:16-alpine`, so this is only relevant if you point `--db-source=custom` at an older instance.

### PostgreSQL Options

> **Mikrus shared database isn't an option for n8n.** StackPilot's shared-DB flow works for many apps but not n8n — see the comparison table above for why. Use `--db-source=bundled` or `--db-source=custom`.

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
A: Not with this installer — PostgreSQL is required. n8n's default is SQLite (and that's what plain `docker run n8nio/n8n` gives you), but SQLite is single-writer: it locks up under concurrent runs and corrupts on hard reboots. We'd rather not let you ship that to production by accident, so the script refuses to start without DB credentials. If you really want SQLite, run the upstream image directly.

**Q: How to migrate workflows from Make/Zapier?**
A: Manually — n8n has different connectors. But most popular integrations (Slack, Google Sheets, Stripe) work similarly.
