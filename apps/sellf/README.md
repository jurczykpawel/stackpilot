# Sellf - Your Own Digital Products Sales System

Open source alternative to Gumroad, EasyCart, Teachable.
Sell e-books, courses, templates and licenses without monthly fees or platform commissions.

## Installation

```bash
# Cloud Supabase + Cloudflare domain (interactive setup)
./local/deploy.sh sellf --ssh=ALIAS --domain-type=cloudflare --domain=shop.example.com

# Cloud Supabase (automated, requires prior setup-sellf-config.sh)
./local/deploy.sh sellf --ssh=ALIAS --yes

# Local self-hosted Supabase (deploy supabase first, then sellf)
./local/deploy.sh supabase --ssh=ALIAS --domain-type=local --yes
./local/deploy.sh sellf --ssh=ALIAS --supabase=local --domain-type=cloudflare --domain=shop.example.com --yes

# Docker runtime (isolated container, ~200MB RAM)
./local/deploy.sh sellf --ssh=ALIAS --supabase=local --runtime=docker --domain-type=cloudflare --domain=shop.example.com --yes
```

## Requirements

- **RAM:**
  - `pm2` mode (default): ~50MB (Bun + PM2, Node.js standalone)
  - `docker` mode: ~200MB (Docker container, `network_mode: host`)
- **Disk:** ~500MB (IMAGE_SIZE_MB=500, Next.js standalone build)
- **Port:** 3333 (default from `PORT=${PORT:-3333}`)
- **Database:** Supabase (cloud account or self-hosted)

### Services

| Service | Cost | Purpose | Required |
|---------|------|---------|----------|
| **VPS (1GB+ RAM)** | varies | Application hosting | Yes |
| **Supabase** | Free tier available | Database + Auth | Yes |
| **Stripe** | 2.9% + fee/transaction | Payments | No* |
| **Cloudflare** | Free | Turnstile CAPTCHA | No |

*Stripe can be configured later via the Sellf admin panel.

## Runtime Modes

| Mode | RAM | Description |
|------|-----|-------------|
| `pm2` (default) | ~50MB | Bun + PM2, lightweight, backward compatible |
| `docker` | ~200MB | Docker container with `network_mode: host`; reaches local Supabase on `localhost`; automatically stops PM2 on switch |

Switch modes by passing `--runtime=docker` or `--runtime=pm2` to deploy.sh.

## Supabase Modes

| Mode | Description |
|------|-------------|
| `cloud` (default) | External Supabase.com — free tier, no server resources |
| `local` | Self-hosted Supabase Docker on the same VPS — deploy supabase first |

## After Installation

1. Open `https://shop.example.com`
2. Register — the **first registered user gets admin access**
3. Configure Stripe in the admin panel (or set up webhooks now):
   - Webhook URL: `https://shop.example.com/api/webhooks/stripe`
   - Events: `checkout.session.completed`, `payment_intent.succeeded`
   - Copy `whsec_...` signing secret to the panel
4. Optional CAPTCHA: `./local/setup-turnstile.sh shop.example.com ALIAS`

## Multi-Instance

Each domain = separate isolated instance:

```bash
./local/deploy.sh sellf --ssh=ALIAS --domain=shop.example.com --domain-type=cloudflare
./local/deploy.sh sellf --ssh=ALIAS --domain=courses.example.com --domain-type=cloudflare
```

Result on the server:
```
/opt/stacks/sellf-shop/      # PM2: sellf-shop,    port: 3333
/opt/stacks/sellf-courses/   # PM2: sellf-courses, port: 3334
```

Ports are auto-incremented (3333, 3334, 3335...).

## Management

```bash
# PM2 mode
ssh ALIAS "pm2 status"
ssh ALIAS "pm2 logs sellf-shop"
ssh ALIAS "pm2 restart sellf-shop"

# Docker mode
ssh ALIAS "docker logs sellf-shop"
ssh ALIAS "cd /opt/stacks/sellf-shop && docker compose restart"
```

## Automated Setup (CI/CD)

```bash
# Step 1: one-time config collection (opens browser for Supabase login)
./local/setup-sellf-config.sh --ssh=ALIAS --domain=shop.example.com --domain-type=cloudflare

# Step 2: deploy without any prompts
./local/deploy.sh sellf --ssh=ALIAS --yes
```

Configuration is saved to `~/.config/stackpilot/sellf/deploy-config.env` and reused on subsequent deploys.

## Update

```bash
./local/deploy.sh sellf --ssh=ALIAS --update
# or for a specific instance:
./local/deploy.sh sellf --ssh=ALIAS --update --domain=shop.example.com
```

## Additional Scripts

```bash
# Turnstile CAPTCHA
./local/setup-turnstile.sh shop.example.com ALIAS

# Custom SMTP for Supabase emails
./local/setup-supabase-email.sh

# Manual database migrations
SSH_ALIAS=ALIAS ./local/setup-supabase-migrations.sh
```

## Backup

Configuration and app files are in `/opt/stacks/sellf-{subdomain}/admin-panel/`.
Database lives in Supabase (cloud or local). For local Supabase, back up the Supabase stack separately.

## Cost Comparison

| | EasyCart | Gumroad | **Sellf** |
|---|---|---|---|
| Monthly fee | ~$25/mo | $10/mo | **$0** |
| Sales commission | 1-3% | 10% | **0%** |
| Data ownership | — | — | **Yes** |

---

> Sellf: https://github.com/jurczykpawel/sellf
