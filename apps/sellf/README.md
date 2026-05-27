# Sellf - Your Own Digital Products Sales System

Open source alternative to Gumroad, EasyCart, Teachable.
Sell e-books, courses, templates, licenses, and recurring subscriptions or memberships, without monthly fees or platform commissions. Built-in waitlists let you validate demand before you build the product.

> **Never installed software on a server before?** Don't start here. Open **[Sellf's QUICK-START guide](https://github.com/jurczykpawel/sellf/blob/main/docs/QUICK-START.md)** instead — it's a click-by-click walkthrough using only your web browser (no terminal), gets you online in ~20 minutes.

## Pick a deployment target

This folder has four installers. Pick the one that matches what you want.

| Installer | What it does | Best when… | Time |
|-----------|--------------|------------|------|
| **`install-vercel.sh`** | Sellf on Vercel + fresh Supabase Cloud database + Stripe test webhook — all configured automatically | You want zero server management. Vercel and Supabase handle uptime. Free for first months. | ~5 min |
| **`install-netlify.sh`** | Same as above but on Netlify | You prefer Netlify over Vercel | ~3 min |
| **`install-coolify.sh`** | Deploys Sellf via Coolify, either self-hosted (installs Coolify on your VPS for you) or via Coolify Cloud (`--coolify-cloud` flag, $5/mo, you bring an already-registered server) | You want full control on your own server. Lowest long-term cost (free with self-hosted, ~$5/mo with Cloud). **Requires 8 GB+ RAM** on the target VPS in either mode. | ~12 min self-hosted / ~7 min Cloud |
| **`install.sh`** | Sellf on a Linux server via PM2 (no Docker, no Coolify) | You have a cheap VPS like mikr.us (35 PLN/year, 384 MB RAM). Lightest weight. | ~5 min |

**Most users should use `install-vercel.sh`.** Two reasons:
- It's the easiest fully-managed path: free tier covers you until your store has paying customers, no server uptime worries.
- The other scripts assume you've already chosen a path that fits your situation (own VPS, mikr.us, etc.).

`install-coolify.sh` and `install.sh` are documented in detail later in this file. The new cloud scripts (`install-vercel.sh`, `install-netlify.sh`) work the same way as each other, so the docs below describe `install-vercel.sh` as the example.

### How to use `install-vercel.sh` (the easiest path)

**One-time setup on your computer (5 minutes):**

```bash
# 1. Install three CLI tools
npm install -g vercel supabase
brew install stripe/stripe-cli/stripe   # macOS — see https://docs.stripe.com/stripe-cli for Linux/Windows

# 2. Log in to each one (opens a browser tab for each)
vercel login
supabase login
stripe login

# 3. Clone Sellf locally
git clone https://github.com/jurczykpawel/sellf.git ~/sellf
```

**Each new Sellf store (5 minutes):**

```bash
./apps/sellf/install-vercel.sh --repo-path ~/sellf
# Script will ask for your Stripe test keys, then do everything itself.
```

When it finishes you get a working URL like `https://sellf-1234.vercel.app`.

### Use an existing Supabase project (`--skip-supabase`)

All three cloud scripts (`install-vercel.sh`, `install-netlify.sh`, `install-coolify.sh`) create a fresh Supabase project by default. To reuse an existing one — say, because you used Vercel's "Connect Database → Supabase" feature already, or you're deploying the same Sellf to multiple platforms sharing one database:

```bash
./apps/sellf/install-vercel.sh --repo-path ~/sellf \
    --skip-supabase \
    --supabase-url   https://<ref>.supabase.co \
    --supabase-anon  "<public-key-eyJ...>" \
    --supabase-svc   "<private-key-eyJ...>" \
    --supabase-ref   <ref> \
    --db-password    "<your-password>"
```

For the full beginner walkthrough of how to obtain those values, see [SUPABASE-SETUP.md](https://github.com/jurczykpawel/sellf/blob/main/docs/SUPABASE-SETUP.md) in the Sellf repo.

### Coolify (`install-coolify.sh`)

Coolify has two flavors and the installer supports both.

**Self-hosted Coolify** (free; the script installs Coolify on your VPS, then deploys Sellf there):

```bash
./apps/sellf/install-coolify.sh \
    --ssh-host my-vps \
    --repo-path ~/sellf
```

**Coolify Cloud** ($5/mo for 2 servers; you've already signed up at https://app.coolify.io, added your server, and generated an API token in the UI):

```bash
./apps/sellf/install-coolify.sh \
    --coolify-cloud \
    --coolify-token <your-api-token-from-coolify-UI> \
    --server-uuid   <uuid-of-server-already-connected> \
    --repo-path ~/sellf
```

Both modes deploy Sellf to a VPS that **you** own — Coolify Cloud only hosts the management UI, not your application. **Your VPS needs 8 GB RAM or more** in either mode (the Sellf build OOM-kills on 4 GB). Use Hetzner CX32 (€8/mo) or equivalent.

For the full deep dive on which flavor to pick + manual flow + troubleshooting, see Sellf's [DEPLOYMENT-COOLIFY.md](https://github.com/jurczykpawel/sellf/blob/main/docs/DEPLOYMENT-COOLIFY.md).

### Cleaning up after a test

Each cloud script saves a file called `.env.deploy.<project>` next to your Sellf checkout. It contains every ID you need to delete the resources you created:

```bash
cat ~/sellf/.env.deploy.sellf-1234567890
```

Manually delete:

- The Vercel/Netlify/Coolify application (in the respective dashboard)
- The Supabase project (https://supabase.com/dashboard → your project → Settings → General → Delete project)
- The Stripe webhook (https://dashboard.stripe.com/test/webhooks → your endpoint → ... → Delete)

There's no `uninstall` command yet — destruction is manual on purpose, since you might want to keep the Supabase project even after deleting the deployment.

---

## `install.sh` — VPS deployment via PM2 (mikr.us flow)

The rest of this document is about `install.sh`, the original installer that targets cheap Linux VPSes (e.g. mikr.us) and runs Sellf with PM2 directly (no Docker, no Coolify, no managed platform).

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
   - One-time payment events: `checkout.session.completed`, `payment_intent.succeeded`, `payment_intent.payment_failed`
   - Subscription events (only needed if you sell recurring products): `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `customer.subscription.trial_will_end`, `invoice.payment_succeeded`, `invoice.payment_failed`
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

> Sellf on Mikrus 1.0 at 35 PLN/year is a real choice for a digital creator with a list of a few thousand subscribers who wants to sell e-books, courses, templates, or run a recurring membership without paying platform commissions.

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
