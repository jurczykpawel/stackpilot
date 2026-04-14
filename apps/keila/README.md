# Keila - Email Marketing Platform

**Self-hosted alternative to Mailchimp, Brevo, and Klaviyo.**
Open-source newsletter and campaign management with no subscriber limits.

> **Official site:** https://www.keila.io

---

## Why Keila?

| | Mailchimp | Brevo | **Keila** |
|---|---|---|---|
| 1,000 subscribers | $0 | $0 | **$0** |
| 10,000 subscribers | ~$100/mo | ~$25/mo | **$0** |
| 50,000 subscribers | ~$350/mo | ~$75/mo | **$0** |

You only pay for hosting and SMTP sending (e.g. Amazon SES: ~$1 per 10,000 emails).

---

## Requirements

- **RAM:** 512MB (container limit; ~150-250MB typical usage)
- **Disk:** ~200MB image (pentacent/keila:latest — Elixir/Phoenix)
- **Port:** 4500 (default: `PORT=${PORT:-4500}`)
- **Database:** PostgreSQL (required)

### PostgreSQL Options

**Option A — Bundled PostgreSQL 16 (dedicated container, easiest):**
```bash
./local/deploy.sh keila --ssh=ALIAS --domain-type=cloudflare --domain=email.example.com --db-source=bundled
```

**Option B — External/custom PostgreSQL:**
```bash
./local/deploy.sh keila --ssh=ALIAS --domain-type=cloudflare --domain=email.example.com --db-source=custom
```

---

## Installation

```bash
# With bundled PostgreSQL (recommended for quick start):
./local/deploy.sh keila --ssh=ALIAS --domain-type=cloudflare --domain=email.example.com --db-source=bundled

# With external PostgreSQL:
./local/deploy.sh keila --ssh=ALIAS --domain-type=cloudflare --domain=email.example.com --db-source=custom

# Local access only (SSH tunnel):
./local/deploy.sh keila --ssh=ALIAS --domain-type=local --db-source=bundled --yes
```

---

## After Installation

1. Open the URL shown after installation
2. **Register your account** — the first registered user becomes admin
3. Go to **Settings → Senders** and add your SMTP server
4. Create a list, import subscribers, and start sending campaigns

### SSH tunnel (local access):

```bash
ssh -L 4500:localhost:4500 ALIAS
# Then open http://localhost:4500
```

---

## SMTP Configuration

Keila does not send emails by itself — you need an SMTP server:

| Service | Cost | Limit |
|---|---|---|
| **Amazon SES** | ~$1 / 10,000 emails | Practically unlimited |
| **Resend** | $0 | 3,000/mo free |
| **Mailgun** | $0 (3 mo.) then $35/mo | 5,000/mo free |
| **Own server** | $0 | Risk of blacklisting |

---

## Features

- Campaign editor (plain text + HTML + Markdown)
- List management with segmentation
- Double opt-in support
- Campaign analytics (opens, clicks)
- Subscriber import/export (CSV)
- REST API
- Webhooks
- Multi-sender support (SMTP)

---

## Backup

Data location: `/opt/stacks/keila/uploads/` (file uploads)

Database backup (if using bundled PostgreSQL):
```bash
ssh ALIAS 'cd /opt/stacks/keila && docker compose exec db pg_dump -U keila keila > /tmp/keila-db.sql'
scp ALIAS:/tmp/keila-db.sql ./keila-db.sql
```
