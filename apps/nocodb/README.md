# NocoDB - Open Source Airtable Alternative

Connects to your own database and turns it into a spreadsheet interface.

## Installation

```bash
./local/deploy.sh nocodb --ssh=ALIAS --domain-type=cloudflare --domain=nocodb.example.com
# or locally (SSH tunnel):
./local/deploy.sh nocodb --ssh=ALIAS --domain-type=local --yes
```

## Requirements

- **RAM:** ~400MB (container limit: 400MB)
- **Disk:** ~400MB (Docker image)
- **Port:** 8080
- **Database:** PostgreSQL (recommended) or SQLite (built-in, no setup required)

PostgreSQL is strongly recommended for production use. SQLite works out of the box but may slow down with larger datasets.

## After Installation

1. Open the URL and create an admin account (first registered user becomes admin).
2. Connect your database: Settings → Team & Auth → Integrations, or use the built-in SQLite for quick start.

## Ecosystem

NocoDB works great as a backend for automations:
- **n8n + NocoDB:** Collect leads from Typebot directly into a NocoDB table.
- **CRM:** Build your own CRM without paying for Pipedrive.
- **Headless CMS:** Use NocoDB as a content source for your website.
