# StackPilot

**The AI-native self-hosting toolkit. Deploy 25+ production-optimized Docker apps to any VPS with a single command.**

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Apps: 25+](https://img.shields.io/badge/Apps-25%2B-blue)
![Any VPS](https://img.shields.io/badge/Platform-Any%20VPS-orange)

[Docs](docs/) | [Issues](https://github.com/jurczykpawel/stackpilot/issues) | [MCP Docs](https://modelcontextprotocol.io/)

---

Replace $300+/month in SaaS subscriptions with a $5/month server. StackPilot is the only self-hosting toolkit with [MCP (Model Context Protocol)](https://modelcontextprotocol.io/) integration -- AI assistants like Claude can deploy and manage apps directly.

```bash
git clone https://github.com/jurczykpawel/stackpilot.git
cd stackpilot
./local/deploy.sh n8n    # n8n is now running on your server
```

---

## Why StackPilot?

- **AI-native deployment**: The only self-hosting toolkit with native MCP integration. AI assistants can deploy, configure, and troubleshoot your apps through natural conversation. No other tool does this.
- **One command, production-ready**: Each app is deployed with a single `deploy.sh` call. Memory limits, log rotation, health checks, security headers, and database provisioning are handled automatically.
- **Zero platform overhead**: No web dashboard to maintain, no background services eating RAM. Just Bash scripts, SSH, and Docker. Your server resources go to your apps, not the platform.
- **Database flexibility**: Bundled containers (auto-provisioned, zero config) or external databases. WordPress also supports SQLite. Your choice, per app.
- **25+ curated apps**: Not a marketplace of untested community templates. Every app config is tuned and tested for small VPS environments (512MB--2GB RAM).

---

## Table of Contents

- [Apps](#apps)
- [How It Works Together](#how-it-works-together)
- [Quick Start](#quick-start)
- [Deployment Modes](#deployment-modes)
- [Domain and HTTPS Setup](#domain-and-https-setup)
- [Savings Calculator](#savings-calculator)
- [Server Requirements](#server-requirements)
- [How It Compares](#how-it-compares)
- [Diagnostics](#diagnostics)
- [FAQ](#faq)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Support](#support)
- [Repository Structure](#repository-structure)
- [Author](#author)
- [License](#license)

---

## Apps

### Automation and Operations

| App | Replaces | Description |
| :--- | :--- | :--- |
| [n8n](apps/n8n/) | Zapier / Make | Workflow automation. Connect CRM, email, payments, APIs. |
| [Uptime Kuma](apps/uptime-kuma/) | UptimeRobot | Uptime monitoring with push/email/Slack alerts. |
| [Dockge](apps/dockge/) | Portainer | Manage Docker Compose stacks via a web UI. |
| [ntfy](apps/ntfy/) | Pushover | Self-hosted push notification server. |
| [Redis](apps/redis/) | - | In-memory cache. Speeds up n8n, WordPress, and others. |

### Communication and Marketing

| App | Replaces | Description |
| :--- | :--- | :--- |
| [Listmonk](apps/listmonk/) | Mailchimp | High-performance newsletter and mailing list manager. |
| [Typebot](apps/typebot/) | Typeform | Conversational forms and chatbots. Lead capture, surveys. |
| [Postiz](apps/postiz/) | Buffer / Hootsuite | Schedule posts to X, LinkedIn, Instagram, Facebook, TikTok. |
| [Cap](apps/cap/) | Loom | Screen recording and video sharing. |
| [Cookie Hub](apps/cookie-hub/) | Cookiebot | Centralized GDPR consent server for all your sites. |

### Web and Content

| App | Replaces | Description |
| :--- | :--- | :--- |
| [WordPress](apps/wordpress/) | WordPress.com | Performance Edition: Nginx + PHP-FPM + Redis Object Cache. |
| [GateFlow](apps/gateflow/) | Gumroad | Digital product storefront. Zero fees, zero commissions. |
| [FileBrowser](apps/filebrowser/) | Dropbox / Tiiny.host | Private file manager with web UI + static hosting. |
| [LinkStack](apps/linkstack/) | Linktree | Link-in-bio page with admin panel. |
| [LittleLink](apps/littlelink/) | Linktree | Ultra-lightweight link-in-bio page (pure HTML). |
| [Umami](apps/umami/) | Google Analytics | Privacy-focused web analytics. No cookies, GDPR-compliant. |
| [AFFiNE](apps/affine/) | Notion / Miro | Knowledge base with docs, whiteboards, and databases. Open-source. |

### Security and Storage

| App | Replaces | Description |
| :--- | :--- | :--- |
| [Vaultwarden](apps/vaultwarden/) | 1Password / Bitwarden | Password manager for individuals and teams. |
| [MinIO](apps/minio/) | AWS S3 | S3-compatible object storage. |

### Developer Tools

| App | Replaces | Description |
| :--- | :--- | :--- |
| [Stirling PDF](apps/stirling-pdf/) | Adobe Acrobat | Edit, merge, sign PDFs in the browser. |
| [Gotenberg](apps/gotenberg/) | - | Document conversion API (HTML/DOCX/ODT to PDF). ~150MB RAM. |
| [ConvertX](apps/convertx/) | CloudConvert | Convert 800+ file formats in the browser. |
| [NocoDB](apps/nocodb/) | Airtable | Spreadsheet-style database. CRM, projects, orders. |
| [MCP Docker](apps/mcp-docker/) | - | Let AI assistants manage Docker containers on your server. |

### AI and Data

| App | Replaces | Description |
| :--- | :--- | :--- |
| [PicoClaw](apps/picoclaw/) | OpenClaw | Ultra-lightweight AI assistant (Telegram/Discord/Slack). ~10MB image, 64MB RAM. Security-hardened. |
| [Crawl4AI](apps/crawl4ai/) | ScrapingBee | AI web scraper with REST API. Markdown output, JS rendering. |
| [Coolify](apps/coolify/) | Heroku / Vercel | Full PaaS with 280+ one-click apps. Requires 8GB+ RAM. |

> Every app has its own `README.md` with detailed docs, requirements, and configuration options.

---

## How It Works Together

These apps are not isolated islands. Together they form a **business operating system**.

**Example: automated e-book sales funnel**

```
Customer --> Typebot (chatbot) --> GateFlow (Stripe payment)
                                        |
                                  n8n (webhook)
                                 /    |    \     \
                            NocoDB  Email  Invoice  Listmonk
                            (CRM)  (ebook)  (API)  (newsletter)
                                        |
                                  Umami (conversion)
```

1. **Typebot** -- the customer chats with a bot that qualifies their needs
2. **GateFlow** -- the bot directs them to checkout for the e-book
3. **n8n** -- detects the payment and automatically: adds the customer to CRM (**NocoDB**), sends the e-book via email, generates an invoice, subscribes them to a newsletter (**Listmonk**)
4. **Umami** -- tracks the conversion

Everything on your server. Zero per-execution fees. Zero limits.

---

## Quick Start

### Prerequisites

- A VPS with 1GB+ RAM (Hetzner, DigitalOcean, Vultr, Linode, OVH, or any provider)
- A domain name (optional but recommended)
- A terminal with SSH access

### 1. Set up SSH

```bash
# Linux / macOS
bash <(curl -s https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/local/setup-ssh.sh)

# Windows (PowerShell)
iwr -useb https://raw.githubusercontent.com/jurczykpawel/stackpilot/main/local/setup-ssh.ps1 | iex
```

The script generates an SSH key, configures `~/.ssh/config` with the alias `vps`, and copies the key to your server.

### 2. Clone the toolkit

```bash
git clone https://github.com/jurczykpawel/stackpilot.git
cd stackpilot
```

### 3. Install foundations and deploy

```bash
./local/deploy.sh system/docker-setup.sh    # Docker + log optimization
./local/deploy.sh system/caddy-install.sh   # Reverse proxy with auto-SSL
./local/deploy.sh n8n                       # Your first app
```

`deploy.sh` handles everything: checks server resources, prompts for domain and database configuration, deploys the app, and verifies it is running.

### 4. Set up backups

```bash
./local/setup-backup.sh     # Encrypted backup to Google Drive / Dropbox / S3
```

---

## Deployment Modes

StackPilot supports two deployment modes: **CLI** for direct control, and **AI/MCP** for conversational deployment.

### CLI Mode

Run `deploy.sh` from your local machine. It connects to your server over SSH, handles domain configuration, database provisioning, and health checks.

```bash
./local/deploy.sh <app> [options]

# Options:
#   --ssh=ALIAS           SSH alias (default: vps)
#   --domain-type=TYPE    cloudflare | caddy | local
#   --domain=DOMAIN       Your domain (e.g. n8n.example.com)
#   --db-source=SOURCE    bundled | custom
#   --yes, -y             Skip all confirmation prompts

# Examples:
./local/deploy.sh n8n --domain-type=cloudflare --domain=n8n.example.com
./local/deploy.sh uptime-kuma --domain-type=local --yes
./local/deploy.sh wordpress --domain-type=caddy --domain=blog.example.com
```

### AI/MCP Mode

Install the MCP server and let Claude (or any MCP-compatible AI) deploy apps conversationally.

```bash
npx stackpilot-mcp
```

Or add it to your Claude Code MCP config:

```json
{
  "mcpServers": {
    "stackpilot": {
      "command": "npx",
      "args": ["-y", "stackpilot-mcp"]
    }
  }
}
```

Then talk to Claude naturally:

- *"Deploy n8n on my server"*
- *"Set up Uptime Kuma with a Cloudflare domain"*
- *"Check server status and free RAM"*
- *"Configure backups to Google Drive"*

The AI handles SSH connection, port allocation, domain setup, database provisioning, and post-deploy verification.

---

## Domain and HTTPS Setup

Three options, depending on your needs:

| Method | Setup | SSL | Best for |
| :--- | :--- | :--- | :--- |
| **Caddy auto-HTTPS** | Automatic | Let's Encrypt | Most users. Zero config HTTPS. |
| **Cloudflare DNS** | One-time setup | Cloudflare + Let's Encrypt | Custom domains, CDN, DDoS protection. |
| **SSH tunnel** | None | N/A | Local development, testing. |

### Caddy (recommended)

Caddy is installed during [Quick Start](#quick-start) and automatically provisions Let's Encrypt certificates for every domain you expose.

```bash
ssh vps 'sp-expose n8n.example.com 5678'
```

### Cloudflare

For custom domains with Cloudflare DNS management:

```bash
./local/setup-cloudflare.sh                   # One-time API token setup
./local/dns-add.sh n8n.example.com            # Add DNS record
ssh vps 'sp-expose n8n.example.com 5678'      # Expose with HTTPS
```

Details: [docs/cloudflare-domain-setup.md](docs/cloudflare-domain-setup.md)

### SSH tunnel (no domain needed)

Access any app locally without a public domain:

```bash
ssh -L 5678:localhost:5678 vps
# Open http://localhost:5678 in your browser
```

Details: [docs/ssh-tunnels.md](docs/ssh-tunnels.md)

---

## Savings Calculator

### Self-hosted vs. SaaS

| Tool | Replaces | SaaS price/month | Self-hosted |
| :--- | :--- | :--- | :--- |
| n8n | Zapier Pro | $29--99 | $0 |
| Listmonk | Mailchimp (5k contacts) | $50+ | $0 |
| Typebot | Typeform Pro | $50+ | $0 |
| NocoDB | Airtable Pro | $20+ | $0 |
| GateFlow | Gumroad (10% commission) | $$$ | $0 |
| Uptime Kuma | UptimeRobot Pro | $7+ | $0 |
| Vaultwarden | 1Password Teams | $8/user | $0 |
| Postiz | Buffer Pro | $15+ | $0 |
| WordPress | WordPress.com Business | $25+ | $0 |
| Stirling PDF | Adobe Acrobat Pro | $15+ | $0 |
| Cap | Loom Business | $15+ | $0 |
| FileBrowser | Tiiny.host Pro | $6+ | $0 |
| ConvertX | CloudConvert | $9+ | $0 |
| Umami | Plausible | $9+ | $0 |
| Crawl4AI | ScrapingBee | $49+ | $0 |
| **Total SaaS** | | **~$300+/month** | |

### Example: solopreneur selling courses

**SaaS stack:** Zapier + Mailchimp + Typeform + UptimeRobot + hosting = **~$150/month (~$1,800/year)**

**StackPilot:** Any VPS with 2GB RAM (~$5/month) + domain (~$10/year) = **~$70/year**

**Savings: ~$1,730/year (96%)**

---

## Server Requirements

| Stack | RAM |
| :--- | :--- |
| Base (Caddy + Dockge) | ~100MB |
| + n8n | ~500MB |
| + Listmonk + Uptime Kuma | ~800MB |
| + Typebot + GateFlow | ~1.5GB |
| Full stack (10+ tools) | ~1.8GB |
| Coolify (PaaS, 280+ apps) | ~500--800MB (platform only) |

> Stirling PDF and Crawl4AI require 2GB+ RAM. Lightweight alternative for PDF conversion: Gotenberg (~150MB).

---

## How It Compares

| | StackPilot | Coolify | Dokku | Kamal |
| :--- | :--- | :--- | :--- | :--- |
| **Approach** | Bash + SSH + Docker | Full PaaS platform | Git-push PaaS | Docker/SSH deploy tool |
| **GitHub stars** | New | ~50k | ~32k | ~14k |
| **Min. RAM** | 512MB | 2GB+ | 1GB+ | 512MB |
| **AI integration** | Native MCP server | No | No | No |
| **Pre-built apps** | 25 production-optimized | 280+ (community) | Via plugins | None (bring your own) |
| **Complexity** | Single deploy command | Web dashboard | CLI + buildpacks | YAML config files |
| **Dependencies** | Bash, SSH, Docker | Docker, Traefik, PostgreSQL, Redis | Docker, Nginx, buildpacks | Docker, Ruby |
| **Domain/SSL** | Caddy auto-HTTPS or Cloudflare | Traefik + Let's Encrypt | Nginx + Let's Encrypt | Traefik or manual |
| **Best for** | Solopreneurs, small teams | Teams wanting a full PaaS | Heroku-like git workflows | Rails/Docker deployments |

---

## Diagnostics

```bash
# Check if a container is running
ssh vps 'docker ps | grep service-name'

# View logs (last 50 lines)
ssh vps 'cd /opt/stacks/service-name && docker compose logs --tail 50'

# Check if a port responds (200/302 = OK)
ssh vps 'curl -s -o /dev/null -w "%{http_code}" http://localhost:PORT'

# Resource usage across all containers
ssh vps 'docker stats --no-stream'
```

> Access any app without a domain using SSH tunnels: [docs/ssh-tunnels.md](docs/ssh-tunnels.md)

---

## FAQ

**What VPS providers are supported?**
Any provider that gives you a Linux VPS with SSH access: Hetzner, DigitalOcean, Vultr, Linode, OVH, and others. StackPilot only needs Docker and SSH.

**How much RAM do I need?**
512MB handles Caddy + 1 lightweight app. 1GB runs n8n + 2--3 smaller services comfortably. 2GB supports a full stack of 10+ apps. Coolify requires 8GB+.

**How do databases work?**
Apps that need PostgreSQL or MySQL can use a bundled database container (auto-provisioned, zero config) or connect to an external database you provide. WordPress also supports SQLite for simple sites.

**Is this secure?**
Apps run in isolated Docker containers. External access is HTTPS-only via Caddy. Ports are bound to `127.0.0.1` by default. Encrypted off-site backups are supported out of the box.

**How do I update an app?**
Run `deploy.sh` again. The script detects existing installations and pulls the latest Docker image. Data in Docker volumes is preserved.

**Can I deploy custom Docker apps?**
Yes. Via the MCP server, you can deploy any Docker Compose stack -- not just the 25 built-in apps. The AI generates the compose file and deploys it.

**What is MCP?**
[Model Context Protocol](https://modelcontextprotocol.io/) is an open standard that lets AI assistants interact with external tools. StackPilot's MCP server (`stackpilot-mcp`) gives Claude (and other compatible AIs) the ability to deploy apps, check server status, configure domains, and set up backups -- all through natural conversation.

**How is this different from Coolify?**
Coolify is a full PaaS platform (like a self-hosted Heroku) with a web dashboard, built-in Traefik, and its own PostgreSQL/Redis. It is powerful but heavyweight. StackPilot is minimal: Bash scripts + SSH + Docker. No platform overhead, no web UI to maintain. StackPilot also includes native AI/MCP integration that Coolify does not have. Note: Coolify itself can be deployed *via* StackPilot on servers with 8GB+ RAM.

---

## Roadmap

- [x] 25+ production-optimized app deployments
- [x] CLI deploy with interactive prompts
- [x] MCP server for AI-driven deployment
- [x] Caddy auto-HTTPS and Cloudflare DNS integration
- [x] Bundled database provisioning (PostgreSQL, MySQL, SQLite)
- [x] Encrypted backups to Google Drive / Dropbox / S3
- [x] WordPress multi-instance support with shared Redis
- [x] Windows support (PowerShell SSH setup)
- [ ] Web dashboard for server overview
- [ ] One-click app updates with rollback
- [ ] Multi-server management
- [ ] App marketplace with community contributions
- [ ] Monitoring dashboard (resource usage, alerts)

---

## Contributing

Contributions are welcome. Whether it is a bug report, feature request, new app template, or documentation improvement -- all contributions help.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow, commit conventions, and how to submit a pull request.

---

## Support

If you run into issues or have questions:

- **Bug reports and feature requests**: [GitHub Issues](https://github.com/jurczykpawel/stackpilot/issues)
- **Discussions**: [GitHub Discussions](https://github.com/jurczykpawel/stackpilot/discussions)

---

## Repository Structure

```
local/           -> User-facing scripts (deploy, backup, setup, DNS)
apps/<app>/      -> App installers: install.sh + README.md
lib/             -> Shared libraries (CLI parser, DB setup, domain setup, health checks)
system/          -> System scripts (Docker, Caddy, backup, power tools)
docs/            -> Documentation (Cloudflare, backups, SSH tunnels, CLI reference)
```

Configuration is stored in `~/.config/stackpilot/`.

---

## Author

**Pawel** ([@jurczykpawel](https://github.com/jurczykpawel))

- [GateFlow](https://github.com/jurczykpawel/gateflow) -- Open-source digital product storefront
- [StackPilot](https://github.com/jurczykpawel/stackpilot) -- The AI-native self-hosting toolkit

---

## License

MIT -- see [LICENSE](LICENSE) for details.

---

*Self-hosted infrastructure toolkit. Deploy 25+ open-source apps (n8n, WordPress, Listmonk, Typebot, NocoDB, Vaultwarden, and more) to any VPS with one command. Replace $300+/month in SaaS subscriptions with a $5/month server.*
