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

### PostgreSQL (required)

Listmonk requires a PostgreSQL database with the **pgcrypto** extension (since v6.0.0).

> **The bundled shared database does NOT work!** No permissions to create extensions. You need a dedicated PostgreSQL database.

#### Dedicated PostgreSQL Database

Use a managed PostgreSQL service or provision a dedicated database instance. A small 512MB/10GB instance is sufficient for most use cases.

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
./local/deploy.sh listmonk
```

The script will ask for:
- PostgreSQL database credentials (host, database, user, password)
- Domain (e.g. `newsletter.example.com`)

### Step 3: Configure the domain

After installation, expose the app via HTTPS:

**Caddy:**
```bash
sp-expose newsletter.example.com 9000
```

### Step 4: Log in and configure SMTP

1. Go to `https://newsletter.example.com`
2. Log in: **admin** / **listmonk**
3. **Change the password!**
4. Go to Settings -> SMTP and configure the mail server

---

## SMTP Configuration

Listmonk does not send emails by itself - you need an SMTP server:

| Service | Cost | Limit |
|---|---|---|
| **Amazon SES** | ~$1 / 10,000 emails | Practically unlimited |
| **Mailgun** | $0 (3 mo.) then $35/mo | 5,000/mo free |
| **Resend** | $0 | 3,000/mo free |
| **Own server** | $0 | Risk of blacklisting |

> **Recommendation:** Amazon SES - cheapest at scale, requires domain verification.

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

**`setup-listmonk-mail.sh`** — wrapper: calls the above + adds:

| Element | What it does |
|---|---|
| **Bounce handling** | PUT /api/settings — SES webhook ON, count=1, action=blocklist |
| **Notifications** | PUT /api/settings — notification emails |
| **Restart** | docker compose restart via --ssh=ALIAS |

Requires prior Cloudflare configuration (`./local/setup-cloudflare.sh`) for automatic DNS record creation.

### Manual configuration

If you prefer not to use the script, add manually in Cloudflare DNS:

**DKIM (for each domain, from SES/EmailLabs panel):**
- 3 CNAME records from the SES console (Authentication -> DKIM)
- 1 CNAME/TXT record from the EmailLabs panel

**DMARC (for each domain):**
```
_dmarc.yourdomain.com  TXT  "v=DMARC1; p=none; rua=mailto:dmarc-reports@yourdomain.com"
```

**Bounce handling:**
1. AWS SNS -> topic `listmonk-bounces` -> subscription HTTPS -> `https://YOUR-LISTMONK/webhooks/service/ses`
2. AWS SES -> each domain -> Notifications -> Bounce + Complaint -> topic `listmonk-bounces`
3. Listmonk -> Settings -> Bounces -> Enable SES, count=1, action=blocklist

---

## Integration with n8n

After a purchase in GateFlow or a conversation in Typebot, you can automatically add people to Listmonk.

**Example n8n workflow:**
```
[Webhook from GateFlow] -> [HTTP Request to Listmonk API] -> [Add to "Customers" list]
```

Listmonk API: `https://listmonk.app/docs/apis/subscribers/`

---

## FAQ

**Q: How much RAM does Listmonk use?**
A: ~50-100MB. Written in Go, very lightweight.

**Q: Can I import subscribers from Mailchimp?**
A: Yes! Export CSV from Mailchimp and import in Listmonk -> Subscribers -> Import.

**Q: How to avoid spam?**
A: Configure SPF, DKIM and DMARC for your domain. Listmonk has built-in double opt-in support.
