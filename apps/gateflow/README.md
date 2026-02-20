# GateFlow - Your Own Digital Products Sales System

**Open source alternative to Gumroad, EasyCart, Teachable.**
Sell e-books, courses, templates and licenses without monthly fees or platform commissions.

**RAM:** ~300MB | **Disk:** ~500MB | **Plan:** 1GB+ RAM VPS

> **Note:** In examples we use `--ssh=ALIAS` as the default SSH alias.
> If you have a different alias in `~/.ssh/config`, replace `ALIAS` with yours (e.g. `srv1`, `myserver`).

---

## Two Installation Modes

GateFlow supports **two** installation modes:

| Mode | For whom | Description |
|------|----------|-------------|
| **Interactive** | First installation | Script asks questions step by step |
| **Automatic** | CI/CD, MCP, repeatable deploys | All keys from CLI or saved configuration |

---

## Quick Start

### Interactive mode (simplest)

```bash
./local/deploy.sh gateflow --ssh=ALIAS
```

The script will guide you through:
1. Logging into Supabase (opens browser)
2. Selecting a Supabase project
3. Stripe keys (optional - can be added later)
4. Domain configuration
5. Turnstile CAPTCHA (optional)

### Automatic mode (for advanced users)

```bash
# STEP 1: One-time configuration (collects and saves all keys)
./local/setup-gateflow-config.sh

# STEP 2: Deployment (fully automatic, no questions)
./local/deploy.sh gateflow --ssh=ALIAS --yes
```

---

## Requirements

| Service | Cost | Purpose | Required |
|---------|------|---------|----------|
| **VPS (1GB+ RAM)** | varies | Application hosting | Yes |
| **Supabase** | Free | Database + Auth | Yes |
| **Stripe** | 2.9% + fee/transaction | Payments | No* |
| **Cloudflare** | Free | Turnstile CAPTCHA | No |

*Stripe can be configured later in the GateFlow panel.

### Before installation, create accounts:

1. **Supabase** - https://supabase.com (create a project)
2. **Stripe** - https://dashboard.stripe.com/apikeys (optional)
3. **Cloudflare** - https://dash.cloudflare.com (optional, for Turnstile)

---

## Interactive Mode (details)

### Basic command

```bash
./local/deploy.sh gateflow --ssh=ALIAS
```

### Optional parameters

```bash
# With Caddy domain (automatic subdomain)
./local/deploy.sh gateflow --ssh=ALIAS --domain=auto --domain-type=caddy

# With your own domain (Cloudflare DNS)
./local/deploy.sh gateflow --ssh=ALIAS --domain=shop.example.com --domain-type=cloudflare

# With a specific Supabase project (skips selection from list)
./local/deploy.sh gateflow --ssh=ALIAS --supabase-project=abcdefghijk
```

### What happens during installation

```
1. Logging into Supabase
   +-- Automatic (opens browser) or
   +-- Manual (paste Personal Access Token)

2. Selecting Supabase project
   +-- List of your projects -> pick a number

3. Stripe configuration (optional)
   +-- Enter pk_... and sk_... keys or
   +-- Skip -> configure in the panel later

4. Domain selection
   +-- Automatic Caddy subdomain
   +-- Custom Caddy subdomain
   +-- Custom Cloudflare domain

5. Turnstile CAPTCHA (optional)
   +-- Automatically via API or manually

6. Installation and startup
   +-- Build -> Start -> Database migrations
```

---

## Automatic Mode (details)

Automatic mode requires **pre-collected keys** using the configuration script.

### Step 1: Collecting keys

```bash
./local/setup-gateflow-config.sh
```

The script collects and saves to `~/.config/gateflow/deploy-config.env`:
- Supabase token + project keys
- Stripe keys (optional)
- Turnstile keys (optional)
- SSH alias
- Domain

### Step 2: Automatic deployment

```bash
./local/deploy.sh gateflow --ssh=ALIAS --yes
```

The `--yes` flag means:
- No interactive questions
- Uses saved configuration
- Automatic Turnstile configuration (if you have a Cloudflare token)

### setup-gateflow-config.sh Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `--ssh=ALIAS` | SSH alias for the server | `--ssh=ALIAS` |
| `--domain=DOMAIN` | Domain or `auto` | `--domain=auto` |
| `--domain-type=TYPE` | `caddy` or `cloudflare` | `--domain-type=caddy` |
| `--supabase-project=REF` | Project ref (skips selection) | `--supabase-project=abc123` |
| `--no-supabase` | Without Supabase configuration | |
| `--no-stripe` | Without Stripe configuration | |
| `--no-turnstile` | Without Turnstile configuration | |

### Configuration examples

```bash
# Full interactive configuration
./local/setup-gateflow-config.sh

# Quick configuration with automatic Caddy domain
./local/setup-gateflow-config.sh --ssh=ALIAS --domain=auto

# Without Stripe and Turnstile (Supabase only)
./local/setup-gateflow-config.sh --ssh=ALIAS --no-stripe --no-turnstile

# With a specific Supabase project
./local/setup-gateflow-config.sh --ssh=ALIAS --supabase-project=grinnleqqyygznnbpjzc --domain=auto

# With custom Cloudflare domain
./local/setup-gateflow-config.sh --ssh=ALIAS --domain=shop.example.com --domain-type=cloudflare
```

---

## deploy.sh Parameters (for GateFlow)

### Required

| Parameter | Description |
|-----------|-------------|
| `--ssh=ALIAS` | SSH alias from ~/.ssh/config |

### Optional - Supabase

| Parameter | Description |
|-----------|-------------|
| `--supabase-project=REF` | Project ref - skips interactive selection |

### Optional - Domain

| Parameter | Description |
|-----------|-------------|
| `--domain=DOMAIN` | Application domain or `auto` for automatic Caddy domain |
| `--domain-type=TYPE` | `caddy` (auto subdomain) or `cloudflare` (own domain) |

### Optional - Modes

| Parameter | Description |
|-----------|-------------|
| `--yes` | Automatic mode - no questions |
| `--update` | Update existing installation |
| `--build-file=PATH` | Use local .tar.gz file (for private repos) |
| `--dry-run` | Show what would be done without executing |

### Examples

```bash
# Interactive with automatic domain
./local/deploy.sh gateflow --ssh=ALIAS --domain=auto --domain-type=caddy

# Automatic (requires prior configuration)
./local/deploy.sh gateflow --ssh=ALIAS --yes

# Automatic with specific Supabase project
./local/deploy.sh gateflow --ssh=ALIAS --supabase-project=abc123 --yes

# With custom Cloudflare domain
./local/deploy.sh gateflow --ssh=ALIAS --domain=shop.example.com --domain-type=cloudflare --yes

# Update
./local/deploy.sh gateflow --ssh=ALIAS --update

# With local build (private repo)
./local/deploy.sh gateflow --ssh=ALIAS --build-file=~/Downloads/gateflow-build.tar.gz --yes
```

---

## Case Studies

### Case 1: First Installation (beginner)

**Situation:** First time installing GateFlow, you want the script to guide you step by step.

```bash
# Just run
./local/deploy.sh gateflow --ssh=ALIAS

# The script:
# 1. Opens browser for Supabase login
# 2. Shows list of projects to choose from
# 3. Asks for Stripe keys (you can skip)
# 4. Asks about domain (choose automatic)
# 5. Installs and starts
```

### Case 2: CI/CD Deployment

**Situation:** You want to automate deployment in a CI/CD pipeline.

```bash
# ONE-TIME (on local machine):
./local/setup-gateflow-config.sh --ssh=ALIAS --domain=auto

# In CI/CD:
./local/deploy.sh gateflow --ssh=ALIAS --yes
```

### Case 3: Multiple Servers

**Situation:** You have several servers and want to deploy quickly to different ones.

```bash
# Configuration for each server
./local/setup-gateflow-config.sh --ssh=server1 --domain=auto
./local/setup-gateflow-config.sh --ssh=server2 --domain=auto

# Deploy (uses saved configuration)
./local/deploy.sh gateflow --ssh=server1 --yes
./local/deploy.sh gateflow --ssh=server2 --yes
```

### Case 4: Custom Domain with Cloudflare

**Situation:** You have a domain `shop.mysite.com` with DNS in Cloudflare.

```bash
# 1. In Cloudflare: add A record pointing to your server IP
#    shop.mysite.com -> 1.2.3.4

# 2. Configuration
./local/setup-gateflow-config.sh \
  --ssh=ALIAS \
  --domain=shop.mysite.com \
  --domain-type=cloudflare

# 3. Deploy
./local/deploy.sh gateflow --ssh=ALIAS --yes
```

### Case 5: Multiple Supabase Projects on One Account

**Situation:** You have two Supabase projects: production and test.

```bash
# Find project ref in URL:
# https://supabase.com/dashboard/project/REF_HERE

# Deploy to test project
./local/deploy.sh gateflow --ssh=staging-server --supabase-project=abc123test --yes

# Deploy to production project
./local/deploy.sh gateflow --ssh=prod-server --supabase-project=xyz789prod --yes
```

### Case 6: Reinstallation After Server Wipe

**Situation:** You wiped the server but have saved configuration.

```bash
# Configuration is in ~/.config/gateflow/deploy-config.env
# Just run:
./local/deploy.sh gateflow --ssh=ALIAS --yes

# The script uses saved Supabase keys, domain, etc.
```

### Case 7: Updating GateFlow

**Situation:** A new version is out and you want to update.

```bash
# Simple update (auto-detects instance)
./local/deploy.sh gateflow --ssh=ALIAS --update

# Update specific instance
./local/deploy.sh gateflow --ssh=ALIAS --update --domain=shop.example.com

# Update with local build (private repo)
./local/deploy.sh gateflow --ssh=ALIAS --update --build-file=~/Downloads/gateflow-build.tar.gz
```

### Case 8: Multiple Instances on One Server (same database)

**Situation:** You want to run several shops on one VPS, using the same Supabase project.

```bash
# First instance - main shop
./local/deploy.sh gateflow --ssh=ALIAS --domain=shop.example.com --domain-type=cloudflare

# Second instance - online courses
./local/deploy.sh gateflow --ssh=ALIAS --domain=courses.example.com --domain-type=cloudflare

# Third instance - different domain
./local/deploy.sh gateflow --ssh=ALIAS --domain=digital.otherdomain.com --domain-type=cloudflare
```

**Result on the server:**
```
/opt/stacks/gateflow-shop/      # PM2: gateflow-shop,    port: 3333
/opt/stacks/gateflow-courses/   # PM2: gateflow-courses, port: 3334
/opt/stacks/gateflow-digital/   # PM2: gateflow-digital, port: 3335
```

Each instance:
- Has its own directory and PM2 process
- Can have its own Stripe configuration
- Port is auto-incremented (3333, 3334, 3335...)

**Updating a specific instance:**
```bash
./local/deploy.sh gateflow --ssh=ALIAS --update --domain=courses.example.com
```

### Case 9: Multiple Instances with Different Databases

**Situation:** You want completely independent shops - each with its own Supabase database.

```bash
# Check your Supabase projects
# https://supabase.com/dashboard/projects

# Instance 1: Production (project: gateflow-prod)
./local/deploy.sh gateflow --ssh=ALIAS \
  --supabase-project=abc123prod \
  --domain=shop.example.com \
  --domain-type=cloudflare \
  --yes

# Instance 2: Tests (project: gateflow-test)
./local/deploy.sh gateflow --ssh=ALIAS \
  --supabase-project=xyz789test \
  --domain=test.example.com \
  --domain-type=cloudflare \
  --yes

# Instance 3: Client demo (project: gateflow-demo)
./local/deploy.sh gateflow --ssh=ALIAS \
  --supabase-project=demo456client \
  --domain=demo.example.com \
  --domain-type=cloudflare \
  --yes
```

**Result on the server:**
```
/opt/stacks/gateflow-shop/   # Supabase: abc123prod,  port: 3333
/opt/stacks/gateflow-test/   # Supabase: xyz789test,  port: 3334
/opt/stacks/gateflow-demo/   # Supabase: demo456client, port: 3335
```

**Key parameter:** `--supabase-project=REF` lets you choose a different Supabase project for each instance.

**Verify configuration:**
```bash
# Check which project each instance uses
ssh ALIAS "grep SUPABASE_URL /opt/stacks/gateflow-*/admin-panel/.env.local"
```

---

## Where Keys Are Stored

### On the local machine

```
~/.config/gateflow/
+-- deploy-config.env    # Main configuration (setup-gateflow-config.sh)
+-- supabase.env         # Backup of Supabase keys

~/.config/supabase/
+-- access_token         # Personal Access Token Supabase

~/.config/cloudflare/
+-- turnstile_token      # Cloudflare API token
+-- turnstile_account_id # Account ID
+-- turnstile_keys_DOMAIN # Turnstile keys per domain
```

### On the server

```
# Single instance (auto-domain or first installation)
~/gateflow/
+-- admin-panel/
|   +-- .env.local           # Application configuration
|   +-- .next/standalone/    # Built application
+-- .env.local.backup        # Backup (on update)

# Multi-instance (each domain = separate directory)
~/gateflow-shop/             # domain: shop.example.com
~/gateflow-courses/          # domain: courses.example.com
~/gateflow-demo/             # domain: demo.example.com
```

---

## Management

```bash
# Status of all instances
ssh ALIAS "pm2 status"

# Logs for a single instance
ssh ALIAS "pm2 logs gateflow-admin"           # auto-domain
ssh ALIAS "pm2 logs gateflow-shop"            # shop.example.com

# Restart
ssh ALIAS "pm2 restart gateflow-admin"

# Restart all GateFlow instances
ssh ALIAS "pm2 restart all"

# Live logs
ssh ALIAS "pm2 logs gateflow-shop --lines 50"

# Check Supabase configuration for all instances
ssh ALIAS "grep SUPABASE_URL /opt/stacks/gateflow*/admin-panel/.env.local"
```

> **Note:** If `pm2: command not found`, add PATH manually:
> ```bash
> ssh ALIAS "echo 'export PATH=\"\$HOME/.bun/bin:\$PATH\"' >> ~/.bashrc"
> ```
> New GateFlow installations add this automatically.

---

## Additional Scripts

### setup-turnstile.sh - CAPTCHA

```bash
# Automatically creates a Turnstile widget for the domain
./local/setup-turnstile.sh shop.example.com ALIAS
```

### setup-supabase-email.sh - SMTP

```bash
# Configures custom SMTP for sending emails
./local/setup-supabase-email.sh
```

### setup-supabase-migrations.sh - Database Migrations

```bash
# Manual migration run (normally automatic)
SSH_ALIAS=ALIAS ./local/setup-supabase-migrations.sh
```

---

## Stripe Webhooks (after installation)

1. Open: https://dashboard.stripe.com/webhooks
2. Add endpoint: `https://YOUR-DOMAIN/api/webhooks/stripe`
3. Events:
   - `checkout.session.completed`
   - `payment_intent.succeeded`
   - `payment_intent.payment_failed`
4. Copy Signing Secret (`whsec_...`)
5. Add to configuration:
   ```bash
   ssh ALIAS "echo 'STRIPE_WEBHOOK_SECRET=whsec_...' >> ~/gateflow/admin-panel/.env.local"
   ssh ALIAS "pm2 restart gateflow-admin"
   ```

---

## FAQ

**Q: What is the difference between interactive and automatic mode?**

A: Interactive asks questions step by step - ideal for beginners. Automatic uses saved keys and the `--yes` flag - ideal for CI/CD and repeatable deploys.

**Q: Do I need to run setup-gateflow-config.sh before every deploy?**

A: No! Once is enough. The configuration is saved and used automatically on subsequent deploys with `--yes`.

**Q: What if I want to change the Supabase project?**

A: Run `./local/setup-gateflow-config.sh` again and select a different project, or use `--supabase-project=NEW_REF`.

**Q: Is the first user the admin?**

A: Yes! The first person to register automatically gets admin privileges.

**Q: Test card for Stripe?**

A: `4242 4242 4242 4242` (any date, any CVC)

**Q: Where do I find the Supabase project ref?**

A: In the project URL: `https://supabase.com/dashboard/project/REF_HERE`

**Q: Is Turnstile required?**

A: No. It is optional CAPTCHA protection. You can configure it later or skip it.

**Q: Can I have multiple GateFlow instances on one server?**

A: Yes! Each instance must have a different domain. The system automatically:
- Creates a separate directory (`/opt/stacks/gateflow-{subdomain}/`)
- Assigns the next port (3333, 3334, 3335...)
- Creates a separate PM2 process

You can also use different Supabase projects for each instance via `--supabase-project=REF`.

**Q: How to check the status of multiple instances?**

A: `ssh ALIAS "pm2 list"` - shows all GateFlow processes with their status.

---

## Cost Comparison

| | EasyCart | Gumroad | **GateFlow** |
|---|---|---|---|
| Monthly fee | ~$25/mo | $10/mo | **$0** |
| Sales commission | 1-3% | 10% | **0%** |
| Data ownership | - | - | **Yes** |

**Save thousands per year** by self-hosting GateFlow on your VPS.

---

> GateFlow: https://github.com/jurczykpawel/gateflow
