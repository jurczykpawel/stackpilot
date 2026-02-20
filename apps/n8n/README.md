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

- **RAM:** Min. 600MB (recommended 1GB on a 2GB VPS)
- **PostgreSQL:** Required (external database!)

> **IMPORTANT:** Do not install PostgreSQL locally on a small VPS - you will run out of RAM for n8n itself!

### PostgreSQL Options

> **The bundled shared database does NOT work!** n8n requires the `pgcrypto` extension (`gen_random_uuid()`), which is not available on shared PostgreSQL 12. You need a dedicated database.

#### Dedicated PostgreSQL Database (required)

Use a managed PostgreSQL service or provision a dedicated database instance. A small 512MB/10GB instance is sufficient and can be shared between n8n, Listmonk and Umami.

---

## Installation

### Step 1: Prepare database credentials

From your database provider you need:
- **Host** - e.g. `db.example.com` or your DB server address
- **Database** - database name
- **User** - username
- **Password** - password

### Step 2: Run the installer

```bash
./local/deploy.sh n8n
```

The script will ask for:
- PostgreSQL database credentials
- Domain (e.g. `n8n.example.com`)

### Step 3: Configure the domain

**Caddy:**
```bash
sp-expose n8n.example.com 5678
```

---

## Backup

n8n stores workflows in the database and encryption keys (credentials) in a file.

Full backup:
```bash
./local/deploy.sh apps/n8n/backup.sh
```

Creates a `.tar.gz` in `/opt/stacks/n8n/backups` on the server.

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
[GateFlow - sales] --webhook--> [n8n]
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
A: 400-600MB at rest, more with complex workflows.

**Q: Can I use SQLite instead of PostgreSQL?**
A: You can, but it is not recommended. SQLite locks up under many concurrent operations.

**Q: How to migrate workflows from Make/Zapier?**
A: Manually - n8n has different connectors. But most popular integrations (Slack, Google Sheets, Stripe) work similarly.
