# StackPilot MCP Server

> **Alpha** - This server is in early development. The core tools work, but expect rough edges, missing validations, and evolving APIs. Feedback and bug reports welcome via [Issues](https://github.com/jurczykpawel/stackpilot/issues).

MCP (Model Context Protocol) server for deploying self-hosted apps to any VPS.

Allows AI assistants (Claude Desktop, etc.) to set up SSH connections, browse available apps, deploy applications, and even install custom Docker apps - all via natural language.

## Quick Start

### 1. Run with npx (no install needed)

```bash
npx stackpilot-mcp
```

### 2. Or configure Claude Desktop

Add to `~/.claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "stackpilot": {
      "command": "npx",
      "args": ["stackpilot-mcp"]
    }
  }
}
```

### 3. Or build from source

```bash
cd mcp-server
npm install
npm run build
```

Then configure Claude Desktop to use the local build:

```json
{
  "mcpServers": {
    "stackpilot": {
      "command": "node",
      "args": ["/path/to/stackpilot/mcp-server/dist/index.js"]
    }
  }
}
```

### 4. Use

In Claude Desktop:

> "Set up SSH connection to my VPS at 203.0.113.10 port 22"

> "What apps can I deploy?"

> "Deploy uptime-kuma with a Cloudflare domain"

> "Install Gitea on my server" *(custom app - AI researches and generates compose)*

> "Check what's running on my server"

## Prerequisites

- **Node.js 18+**
- **stackpilot** repo cloned locally (for CLI-based tools)
- **Any VPS** with SSH access (Ubuntu/Debian recommended)

## Architecture

```
Claude ←stdio→ MCP Server (local) ←shell→ deploy.sh ←SSH→ VPS
```

The MCP server runs on your local machine:
- `setup_server` configures SSH keys and `~/.ssh/config`
- `deploy_app` shells out to `local/deploy.sh` (resource checks, DB setup, domain config)
- `deploy_custom_app` uploads compose files directly via SSH
- `deploy_site` auto-detects local project type, uploads via rsync, starts the service
- `server_status` queries the remote server for container, RAM, and disk info

## Available Tools (9)

### `setup_server`

Set up or test SSH connection to a VPS.

**Setup mode** (new connection):
```
{ host: "203.0.113.10", port: 22, user: "root", alias: "vps" }
```
Generates SSH key, writes `~/.ssh/config`, returns `ssh-copy-id` command for user to run once.

**Test mode** (existing connection):
```
{ ssh_alias: "vps" }
```
Tests connectivity, shows RAM, disk, running containers.

### `list_apps`

List all 25+ tested apps with metadata.

```
{ category: "no-db" }  // Optional filter: all, no-db, postgres, mysql, lightweight
```

Returns app name, description, Docker image size, database requirements, default port, and special notes for each app.

### `deploy_app`

Deploy a tested application from the built-in catalog.

```
{
  app_name: "uptime-kuma",
  domain_type: "cloudflare",
  domain: "status.example.com"
}
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `app_name` | Yes | App to deploy (use `list_apps`) |
| `ssh_alias` | No | SSH alias (default: configured server) |
| `domain_type` | No | `cloudflare`, `caddy`, or `local` |
| `domain` | No | Domain name for the app |
| `db_source` | For DB apps | `bundled` or `custom` |
| `db_host/port/name/user/pass` | If custom | Database credentials |
| `port` | No | Override default port |
| `dry_run` | No | Preview without executing |
| `extra_env` | No | App-specific env vars |

### `deploy_custom_app`

Deploy ANY Docker application - not limited to the built-in list. AI researches the app, generates `docker-compose.yaml`, shows it to user for confirmation, then deploys.

```
{
  name: "gitea",
  compose: "services:\n  gitea:\n    image: gitea/gitea:latest\n    ...",
  confirmed: true,
  port: 3000
}
```

User must explicitly confirm before deployment (`confirmed: true`).

### `deploy_site`

Deploy a LOCAL project directory (website, Node.js app, Python app, Docker project) directly to a VPS. Auto-detects project type and deploys accordingly.

```
{
  project_path: "/path/to/my-project",
  analyze_only: true
}
```

Supported project types (auto-detected): static HTML, Node.js (PM2), Next.js, Python, Dockerfile, Docker Compose.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `project_path` | Yes | Absolute path to local project |
| `analyze_only` | No | Just detect type, no deploy (default: false) |
| `confirmed` | For deploy | Must be `true` to actually deploy |
| `strategy` | No | `auto`, `static`, `node`, `docker` |
| `ssh_alias` | No | SSH alias (default: configured server) |
| `domain_type` | No | `cloudflare`, `caddy`, or `local` |
| `domain` | No | Domain name |
| `port` | No | Override default port |

**Typical flow:** call with `analyze_only: true` first, then with `confirmed: true` after user agrees.

### `server_status`

Check server state: containers, RAM, disk, ports. Warns if Docker is not installed.

```
{ ssh_alias: "vps" }
```

### `setup_domain`

Configure a domain for an app running on a specific port. Supports Caddy reverse proxy with auto-HTTPS or Cloudflare DNS.

```
{
  port: 3001,
  domain: "status.example.com",
  ssh_alias: "vps"
}
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `port` | Yes | Port the app is listening on (1-65535) |
| `domain` | No | Domain to assign |
| `ssh_alias` | No | SSH alias (default: configured server) |

**When to use:** after `deploy_custom_app`, or to add a domain to any running app. NOT needed after `deploy_app` with a domain configured (it handles domain automatically).

### `setup_backup`

Configure automatic backups on a VPS. Auto-installs the toolbox on the server if needed.

```
{ backup_type: "db" }
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `backup_type` | Yes | `db` or `cloud` |
| `ssh_alias` | No | SSH alias (default: configured server) |

**Backup types:**
- `db` -- automatic daily database backup (auto-detects PostgreSQL/MySQL). Runs on server via cron.
- `cloud` -- cloud backup via rclone (Google Drive, Dropbox, S3). Cannot be configured remotely -- returns instructions for the user to run locally.

**Note:** After any `deploy_app`, `deploy_custom_app`, or `deploy_site`, the server is checked for backup configuration. If no backup is found, a warning is returned suggesting `setup_backup`.

### `setup_gateflow_config`

Configure GateFlow deployment credentials (Supabase keys) securely -- without exposing secrets in the conversation.

Multi-step flow:
1. Call with no params -- opens browser for Supabase login, returns instructions
2. Call with `verification_code` -- exchanges code for token, returns project list
3. Call with `project_ref` -- fetches API keys and saves config to `~/.config/stackpilot/gateflow/deploy-config.env`

After setup is complete, `deploy_app(app_name='gateflow')` will use the saved config automatically.

## Example Conversations

### Deploy Uptime Kuma (no database needed)

```
User: "I want to monitor my websites"
AI:   *reads apps/uptime-kuma/README.md*
      "Uptime Kuma is perfect - self-hosted monitoring dashboard
       (replaces UptimeRobot). Uses built-in SQLite, no external
       database needed. Only ~80MB RAM. Want me to install it?"
User: "Yes"
AI:   -> deploy_app { app: "uptime-kuma", domain_type: "cloudflare", domain: "status.example.com" }
       "Done! Uptime Kuma is live at https://status.example.com
        Create your admin account on first visit."
```

### Deploy WordPress with SQLite

```
User: "Set up a WordPress site"
AI:   *reads apps/wordpress/README.md*
      "WordPress Performance Edition (FPM + Nginx + Redis cache).
       Uses only ~80-100MB RAM. You can use SQLite for the database
       which keeps things simple with no external DB required.
       Redis for caching will be bundled automatically."
User: "Go ahead with SQLite"
AI:   -> deploy_app { app: "wordpress", domain_type: "caddy", domain: "blog.example.com",
                      extra_env: { WP_DB_MODE: "sqlite" } }
       "Done! WordPress is live at https://blog.example.com
        Open the URL in your browser to run the WordPress setup wizard."
```

### Deploy n8n with Bundled Database

```
User: "Install n8n for workflow automation"
AI:   *reads apps/n8n/README.md*
      "n8n needs PostgreSQL 13+. I can bundle a PostgreSQL container
       alongside n8n, or you can provide your own database.
       Bundled is simpler - shall I go with that?"
User: "Yes, bundled is fine"
AI:   -> deploy_app { app: "n8n", db_source: "bundled",
                      domain_type: "cloudflare", domain: "n8n.example.com" }
       "Done! n8n is live at https://n8n.example.com
        Create your admin account on first visit.
        I'd recommend setting up backups too."
```

## Smart Guidance (Roadmap)

MCP is not just a "run commands" interface. Because the AI model sees tool descriptions, app metadata (RAM requirements, DB dependencies, ports), and server state, it can **guide the user through the entire setup** like an expert sysadmin. The key: **the model should always read the app's README first** (via `list_apps` metadata) before suggesting anything.

**Key principle:** The model should always read the app's README (via `list_apps` metadata) before suggesting anything. READMEs contain gotchas like pgcrypto requirements, RAM limits, and Redis auto-detection that the model must communicate to the user.

Planned improvements:
- **Resource budgeting** - "You have 1.2GB free RAM. This app needs ~800MB - want to check first?"
- **Post-deploy checklist** - security hardening, SSL verification, backup setup, monitoring
- **Multi-app orchestration** - "Set up my complete solopreneur stack" -> deploys n8n + Listmonk + Uptime Kuma + GateFlow in the right order

## Development

```bash
npm run dev    # Run with tsx (no build needed)
npm run build  # Compile TypeScript
npm start      # Run compiled version
npm test       # Run test suite (no SSH required)
```

Tests cover project detection, input validation, metadata parsing, and tool registration integrity -- all locally, without connecting to any server.

## License

MIT
