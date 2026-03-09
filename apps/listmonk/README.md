# Listmonk - Your Newsletter System

**Alternative to Mailchimp / MailerLite / ActiveCampaign.**
Send emails to thousands of subscribers without monthly fees for your contact list.

> **Official site:** https://listmonk.app

---

## Why Listmonk?

| | Mailchimp | MailerLite | **Listmonk** |
|---|---|---|---|
| 1,000 subscribers | $0 | $0 | **$0** |
| 10,000 subscribers | ~$50/mo | ~$25/mo | **$0** |
| 50,000 subscribers | ~$200/mo | ~$75/mo | **$0** |

You only pay for hosting and sending emails via SMTP (e.g. Amazon SES: ~$1 per 10,000 emails).

---

## Requirements

- **RAM:** 256MB (limit set in docker-compose; ~50-100MB typical usage)
- **Disk:** ~150MB image (listmonk/listmonk:latest — Go binary)
- **Port:** 9000 (default: `PORT=${PORT:-9000}`)
- **Database:** PostgreSQL with `pgcrypto` extension (required since v6.0.0)

### PostgreSQL Options

> **The shared Mikrus database does NOT work!** The shared instance (PostgreSQL 12) does not allow creating extensions like `pgcrypto`. You need a dedicated database.

> **`--db-source=bundled` works correctly.** It starts a dedicated `postgres:16-alpine` container which supports all required extensions.

**Option A — Bundled PostgreSQL 16 (dedicated container, easiest):**
```bash
./local/deploy.sh listmonk --ssh=ALIAS --domain-type=cloudflare --domain=newsletter.example.com --db-source=bundled
```
Starts a dedicated `postgres:16-alpine` container alongside Listmonk. No external DB needed.

**Option B — External/custom PostgreSQL:**
```bash
./local/deploy.sh listmonk --ssh=ALIAS --domain-type=cloudflare --domain=newsletter.example.com --db-source=custom
```
The script will ask for host, database, user, and password. A small 512MB/10GB managed instance is sufficient and can be shared between n8n, Listmonk, and Umami.

> **Note:** Listmonk does not support schema isolation — its tables are always created in the `public` schema of the target database. When sharing a database with other apps, listmonk tables (campaigns, subscribers, lists) will be alongside them.

---

## Installation

```bash
# With bundled PostgreSQL (recommended):
./local/deploy.sh listmonk --ssh=ALIAS --domain-type=cloudflare --domain=newsletter.example.com --db-source=bundled

# With external PostgreSQL:
./local/deploy.sh listmonk --ssh=ALIAS --domain-type=cloudflare --domain=newsletter.example.com --db-source=custom

# Local access only (SSH tunnel):
./local/deploy.sh listmonk --ssh=ALIAS --domain-type=local --db-source=bundled --yes
```

---

## After Installation

1. Go to `https://newsletter.example.com`
2. Log in: **admin** / **listmonk**
3. **Change the password immediately!**
4. Go to **Settings → SMTP** and configure the mail server

### SSH tunnel (local access):

```bash
ssh -L 9000:localhost:9000 ALIAS
# Then open http://localhost:9000
```

---

## SMTP Configuration

Listmonk does not send emails by itself — you need an SMTP server:

| Service | Cost | Limit |
|---|---|---|
| **Amazon SES** | ~$1 / 10,000 emails | Practically unlimited |
| **Mailgun** | $0 (3 mo.) then $35/mo | 5,000/mo free |
| **Resend** | $0 | 3,000/mo free |
| **Own server** | $0 | Risk of blacklisting |

> **Recommendation:** Amazon SES — cheapest at scale, requires domain verification.

---

## Sending Domain Setup (DKIM, DMARC, bounce)

After configuring SMTP, run the domain setup script:

```bash
# Full setup: DNS + Listmonk API + restart
./local/setup-listmonk-mail.sh example.com shop.example.com \
    --listmonk-url=https://newsletter.example.com --ssh=vps

# DNS only (without Listmonk configuration) — works with any mailer
./local/setup-mail-domain.sh example.com shop.example.com

# Audit only — no changes
./local/setup-mail-domain.sh example.com --dry-run
```

**`setup-mail-domain.sh`** — universal DNS script (works with any mailer):

| Element | What it does | Why it matters |
|---|---|---|
| **SPF** | Audits existing records | Without SPF emails are rejected |
| **DKIM** | Adds records from SES/EmailLabs/other to Cloudflare | Without DKIM emails land in spam |
| **DMARC** | Adds policy + cross-domain auth records | Protects against spoofing |
| **Bounce guide** | SNS instructions (if --webhook-url provided) | Without this SES may suspend your account |

Requires prior Cloudflare configuration (`./local/setup-cloudflare.sh`) for automatic DNS record creation.

---

## Backup

Data location: `/opt/stacks/listmonk/data/` (file uploads)

Database backup (if using bundled PostgreSQL):
```bash
ssh ALIAS 'cd /opt/stacks/listmonk && docker compose exec db pg_dump -U listmonk listmonk > /tmp/listmonk-db.sql'
scp ALIAS:/tmp/listmonk-db.sql ./listmonk-db.sql
```

---

## Integration with n8n

After a purchase in Sellf or a conversation in Typebot, you can automatically add people to Listmonk.

**Example n8n workflow:**
```
[Webhook from Sellf] -> [HTTP Request to Listmonk API] -> [Add to "Customers" list]
```

Listmonk API: `https://listmonk.app/docs/apis/subscribers/`

---

## FAQ

**Q: How much RAM does Listmonk use?**
A: ~50-100MB. Written in Go, very lightweight.

**Q: Can I import subscribers from Mailchimp?**
A: Yes! Export CSV from Mailchimp and import in Listmonk → Subscribers → Import.

**Q: How to avoid spam?**
A: Configure SPF, DKIM and DMARC for your domain. Listmonk has built-in double opt-in support.
