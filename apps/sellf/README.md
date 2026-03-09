# Sellf - Your Own Digital Products Sales System

Open source alternative to Gumroad, EasyCart, Teachable.
Sell e-books, courses, templates and licenses without monthly fees or platform commissions.

**RAM:** ~130MB | **Disk:** ~500MB | **Plan:** Mikrus 1.0+ (35 PLN/year)

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
| **Mikrus 1.0+** | 35 PLN/year | Application hosting | Yes |
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
   - Events: `checkout.session.completed`, `payment_intent.succeeded`, `payment_intent.payment_failed`
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

## Does Mikrus at 35 PLN/year work for my shop?

**Yes.** Verified in practice.

We tested Sellf on the cheapest Mikrus plan (384 MB RAM, 35 PLN/year), simulating traffic like after sharing a link on social media.

| Scenario | Page load time | Errors |
|---|:---:|:---:|
| Normal traffic (a few users at once) | under 0.5s | none |
| Medium traffic (30 concurrent users) | ~0.7s | none |
| Heavy traffic (50 concurrent users) | ~1s | none |
| Viral (100 concurrent users) | ~2s | none |

**At 100 concurrent users — zero errors, zero downtime.** The shop works, customers can buy.

For comparison: most small online shops have a handful of concurrent visitors. 100 concurrent is a viral post or ad campaign scenario. Even then — it works.

> Sellf on Mikrus 1.0 at 35 PLN/year is a real choice for a digital creator with a list of a few thousand subscribers who wants to sell e-books, courses, or templates without paying platform commissions.

## Is free Supabase enough?

Sellf uses Supabase only as a database and auth system. If files (PDFs, videos) are hosted on an external CDN, Supabase handles no download traffic — only shop data.

**Estimated database usage for a small shop** (20 products, 1,000 users, 100 transactions/month):

| | Year 1 | Year 2 | Year 3 |
|---|:---:|:---:|:---:|
| Products, configuration | ~100 KB | ~200 KB | ~300 KB |
| Users and access | ~2.5 MB | ~5 MB | ~7 MB |
| Transactions and payments | ~1.3 MB | ~2.6 MB | ~4 MB |
| Logs (audit, webhooks) | ~30 MB | ~60 MB | ~90 MB |
| Video events and analytics | ~10 MB | ~24 MB | ~36 MB |
| PostgreSQL indexes | ~45 MB | ~90 MB | ~135 MB |
| **Total** | **~90 MB** | **~180 MB** | **~270 MB** |

Free Supabase tier gives 500 MB database and 50,000 monthly active users. **For a typical small digital shop, it lasts 3-4 years.**

**At what revenue does free Supabase stop being enough?**

The bottleneck is the **50,000 MAU/month** limit (users who logged in that month, not total registered). The database at that scale stays well below 500 MB.

| Shop stage | Active users/mo | Sales/mo | Revenue/mo | Server | Supabase |
|---|:---:|:---:|:---:|:---:|:---:|
| Launch | ~200 | ~15 | ~$200 | no problem | no problem |
| Growing | ~1,000 | ~50 | ~$1,200 | no problem | no problem |
| Stable | ~3,000 | ~100 | ~$2,500 | no problem | no problem |
| Consider bigger server | ~10,000+ | ~300 | ~$7,500 | depends on traffic* | no problem |
| Upgrade Supabase | ~50,000+ | ~1,000 | ~$25,000 | requires bigger VPS | MAU limit |

*At ~3,000 MAU traffic is spread over time and the server handles it fine. At ~10,000+ MAU it depends on buying patterns: subscribers spread over time is one thing, a product launch to 10,000 subscribers via email is another. Consider a bigger plan or PM2 cluster for that.

When the shop grows and the free plan stops being enough, the natural next step is **self-hosted Supabase** — the toolbox has a ready installer:

```bash
./local/deploy.sh supabase --ssh=ALIAS --domain=db.example.com
```

Self-hosted Supabase requires minimum 2 GB RAM (too much for Mikrus 1.0) but works great on a VPS from ~€5/mo (e.g. Hetzner CAX11). Details: [apps/supabase/README.md](../supabase/README.md).

## Cost Comparison

| | EasyCart | Gumroad | **Sellf** |
|---|---|---|---|
| Monthly fee | ~100 PLN/mo | $10/mo | **0 PLN** |
| Sales commission | 1-3% | 10% | **0%** |
| Data ownership | — | — | **Yes** |
| At 300k PLN/year | ~16-19k PLN | ~30k PLN | **~8.7k PLN** |

**Save 7,000-20,000 PLN/year** by self-hosting Sellf.

## Case Studies

### Case 1: First installation (beginner)

**Situation:** Installing Sellf for the first time, want the script to guide you step by step.

```bash
./local/deploy.sh sellf --ssh=ALIAS

# The script will:
# 1. Open a browser for Supabase login
# 2. Show a list of projects to choose from
# 3. Ask for Stripe keys (you can skip)
# 4. Ask for a domain (choose automatic)
# 5. Install and start
```

### Case 2: CI/CD deployment

**Situation:** Automate deployment in a CI/CD pipeline.

```bash
# ONE-TIME (on your local machine):
./local/setup-sellf-config.sh --ssh=ALIAS --domain=shop.example.com --domain-type=cloudflare

# In CI/CD:
./local/deploy.sh sellf --ssh=ALIAS --yes
```

### Case 3: Multiple servers

**Situation:** You have several servers and want to deploy quickly to different ones.

```bash
./local/setup-sellf-config.sh --ssh=srv1 --domain=auto
./local/setup-sellf-config.sh --ssh=srv2 --domain=auto

./local/deploy.sh sellf --ssh=srv1 --yes
./local/deploy.sh sellf --ssh=srv2 --yes
```

### Case 4: Custom domain with Cloudflare

**Situation:** You have domain `shop.example.com` with DNS in Cloudflare.

```bash
# 1. In Cloudflare: add A record pointing to server IP
# 2. Configure
./local/setup-sellf-config.sh \
  --ssh=ALIAS \
  --domain=shop.example.com \
  --domain-type=cloudflare

# 3. Deploy
./local/deploy.sh sellf --ssh=ALIAS --yes
```

### Case 5: Multiple Supabase projects on one account

**Situation:** You have two Supabase projects: production and staging.

```bash
# Deploy to staging project
./local/deploy.sh sellf --ssh=ALIAS-staging --supabase-project=abc123test --yes

# Deploy to production project
./local/deploy.sh sellf --ssh=ALIAS-prod --supabase-project=xyz789prod --yes
```

### Case 6: Reinstall after wiping the server

**Situation:** Wiped the server but have saved config.

```bash
# Config is in ~/.config/stackpilot/sellf/deploy-config.env
./local/deploy.sh sellf --ssh=ALIAS --yes
# Uses saved Supabase keys, domain, etc.
```

### Case 7: Updating Sellf

**Situation:** New version released, want to update.

```bash
# Simple update (auto-detects instance)
./local/deploy.sh sellf --ssh=ALIAS --update

# Update specific instance
./local/deploy.sh sellf --ssh=ALIAS --update --domain=shop.example.com

# Update with local build (private repo)
./local/deploy.sh sellf --ssh=ALIAS --update --build-file=~/Downloads/sellf-build.tar.gz
```

### Case 8: Multiple instances on one server (same database)

**Situation:** Run several shops on one server, sharing the same Supabase project.

```bash
./local/deploy.sh sellf --ssh=ALIAS --domain=shop.example.com --domain-type=cloudflare
./local/deploy.sh sellf --ssh=ALIAS --domain=courses.example.com --domain-type=cloudflare
./local/deploy.sh sellf --ssh=ALIAS --domain=digital.otherdomain.com --domain-type=cloudflare
```

Result on the server:
```
/opt/stacks/sellf-shop/      # PM2: sellf-shop,    port: 3333
/opt/stacks/sellf-courses/   # PM2: sellf-courses, port: 3334
/opt/stacks/sellf-digital/   # PM2: sellf-digital, port: 3335
```

### Case 9: Multiple instances with different databases

**Situation:** Completely independent shops, each with its own Supabase project.

```bash
# Instance 1: Production (project: sellf-prod)
./local/deploy.sh sellf --ssh=ALIAS \
  --supabase-project=abc123prod \
  --domain=shop.example.com \
  --domain-type=cloudflare \
  --yes

# Instance 2: Staging (project: sellf-test)
./local/deploy.sh sellf --ssh=ALIAS \
  --supabase-project=xyz789test \
  --domain=test.example.com \
  --domain-type=cloudflare \
  --yes

# Instance 3: Client demo (project: sellf-demo)
./local/deploy.sh sellf --ssh=ALIAS \
  --supabase-project=demo456client \
  --domain=demo.example.com \
  --domain-type=cloudflare \
  --yes
```

Result on the server:
```
/opt/stacks/sellf-shop/   # Supabase: abc123prod,    port: 3333
/opt/stacks/sellf-test/   # Supabase: xyz789test,    port: 3334
/opt/stacks/sellf-demo/   # Supabase: demo456client, port: 3335
```

Key parameter: `--supabase-project=REF` selects a different Supabase project per instance.

---

> Sellf: https://github.com/jurczykpawel/sellf
