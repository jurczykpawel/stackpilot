# Typebot - Chatbots and Forms

Typebot is a visual chatbot builder that replaces expensive tools like Typeform.

## Installation

```bash
# With bundled PostgreSQL (recommended for single-server setups)
./local/deploy.sh typebot \
  --ssh=ALIAS \
  --domain-type=cloudflare \
  --domain=typebot.example.com \
  --db-source=bundled \
  --yes

# With external PostgreSQL
./local/deploy.sh typebot \
  --ssh=ALIAS \
  --domain-type=cloudflare \
  --domain=typebot.example.com \
  --db-source=custom \
  --yes
```

Typebot uses two domains: `builder.typebot.example.com` and `typebot.example.com`.
When you pass `--domain=typebot.example.com`, install.sh auto-generates both.

## Requirements

- **RAM:** ~600MB (Builder: 300MB + Viewer: 300MB)
- **Disk:** ~6GB (IMAGE_SIZE_MB=6000 — two Next.js images, ~1.5GB each compressed)
- **Port:** 8081 (Builder), 8082 (Viewer)
- **Database:** PostgreSQL — bundled (PG 16) or external

> **Note on shared DB:** The Mikrus shared database (PostgreSQL 12) does NOT work —
> Typebot's Prisma requires `gen_random_uuid()`, unavailable on PG 12.
> Use `--db-source=bundled` (deploys PostgreSQL 16 alongside Typebot) or provide your own PG 14+.

## After Installation

1. Open `https://builder.typebot.example.com`
2. Register — the first user gets admin access
3. Create your first chatbot
4. Embed on your site via the Viewer URL: `https://typebot.example.com`

> **Note:** S3 storage for file uploads is NOT configured in this lite setup.
> Files uploaded in forms will not be stored. Configure S3 separately if needed.

## "Lazy Engineer" Integration

Typebot is the entry point to your automation system:
1. Client fills out the bot.
2. Bot sends data to **n8n** via webhook.
3. n8n saves data in **NocoDB** and sends a proposal via **Listmonk**.

## Management

```bash
# Logs
ssh ALIAS "cd /opt/stacks/typebot && docker compose logs -f"

# Restart
ssh ALIAS "cd /opt/stacks/typebot && docker compose restart"

# Status
ssh ALIAS "docker ps --filter name=typebot"
```

## Backup

If using bundled DB, the data volume is on the server:
```bash
ssh ALIAS "cd /opt/stacks/typebot && docker compose exec db pg_dump -U typebot typebot > /tmp/typebot.sql"
./local/sync.sh down /tmp/typebot.sql ./backups/ --ssh=ALIAS
```
