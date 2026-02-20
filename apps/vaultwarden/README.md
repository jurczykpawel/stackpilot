# Vaultwarden - Password Vault

Lightweight Bitwarden server written in Rust. All your passwords for every service in one secure place on your server.

## Why Vaultwarden, not Bitwarden?

The official Bitwarden server requires 2-4 GB RAM (8+ containers: .NET, MSSQL, Nginx, Identity, API, Admin...). On a 1 GB RAM VPS it would not even start.

| | Vaultwarden | Bitwarden official |
|---|---|---|
| RAM | ~50 MB | 2-4 GB |
| Containers | 1 | 8+ |
| Database | SQLite | MSSQL |
| Bitwarden clients | 100% compatible | native |
| Premium features | all free | license required |
| Language | Rust | .NET (C#) |

## Installation

```bash
./local/deploy.sh vaultwarden --ssh=ALIAS --domain-type=caddy --domain=auto
```

## Requirements

- **RAM:** ~50MB (Rust, very lightweight)
- **Disk:** ~330MB (Docker image)
- **Database:** SQLite (built-in, zero configuration)
- **Port:** 8088

## HTTPS is MANDATORY

Vaultwarden stores passwords -- **never use it without HTTPS!**
Without TLS encryption, passwords are transmitted in plain text. Always use a domain with an SSL certificate (Caddy or Cloudflare).

The `--domain-type=local` mode (SSH tunnel) is secure locally, but do not expose Vaultwarden publicly without HTTPS.

## After Installation

1. **Register immediately** after starting the service -- the first account becomes admin
2. **Disable registration** for others, so nobody else can create an account:
   ```bash
   ssh ALIAS 'cd /opt/stacks/vaultwarden && sed -i "s/SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/" docker-compose.yaml && docker compose up -d'
   ```
3. **Admin panel** -- token saved in `/opt/stacks/vaultwarden/.admin_token`:
   ```bash
   ssh ALIAS 'cat /opt/stacks/vaultwarden/.admin_token'
   ```
   Access: `https://your-domain.com/admin`
4. Use the **Bitwarden** mobile app and browser extension -- they are fully compatible with Vaultwarden

## Backup

Data in `/opt/stacks/vaultwarden/data/` (SQLite + attachments). Just back up this directory.
