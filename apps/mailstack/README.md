# Mailstack

Forms and transactional email API with an encrypted delivery log, plus the licensed Mailstack Pro panel, webhooks and offsite backups. One command installs one of three profiles:

| Profile | Cloudflare | Your server |
| --- | --- | --- |
| **a** | API Worker + D1, panel Worker + D1, Access on the panel and egress hosts | `cloudflared`, `egress` (webhooks leave here), `backup`, host firewall |
| **b** | API Worker + D1, Access on the internal API, panel and egress hosts | panel, `cloudflared`, `egress`, `backup`, host firewall |
| **c** | Tunnel and Access only | API (Node + SQLite), panel, `cloudflared`, `backup` |

Nothing publishes a port: the panel and (in profile c) the API are reached through a Cloudflare Tunnel; the panel host admits only the owner's e-mail through Cloudflare Access, then a passkey.

## Requirements

- On your computer: Node.js 24+, `ssh` access to the server (root or passwordless `sudo`), clean checkouts of `mailstack` and `mailstack-pro` with `npm ci` done, and the release guard satisfied for profiles a and b: an `instance` named `mailstack` (production) needs `HEAD` equal to `origin/main` or a tag reachable from it; any other instance needs only clean checkouts.
- On the server: Linux with Docker Compose v2.24+, `curl`, `openssl`, `ip`, systemd and iptables (profiles a and b).
- Cloudflare: the hostnames in zones of this account; an API token with Workers Scripts, D1, Workers Custom Domains, Access (apps, service tokens, organization read), Cloudflare Tunnel and DNS edit; a second token with **only** D1 for the backup service. Each API Worker uses one Cron Trigger (five per account on Workers Free).
- Backups: a B2 bucket, two application keys (register key with `readFiles`+`writeFiles`, backup key with `writeFiles` only, see the core `docs/backup.md`) and the owner's `age` public key. The private `age` key never leaves your computer.
- A Mailstack Pro license (Sellf) for the panel.

## Install plan

Keep the plan outside any repository. Secrets are references, never values: `env:NAME`, `file:/path`, `bw:<Vaultwarden item>` (password field) or `keystore:<name>` (`./local/keys.sh`).

```json
{
  "instance": "mailstack",
  "profile": "a",
  "ssh": "vps",
  "accountId": "<32-character account id>",
  "ownerEmail": "owner@example.com",
  "hosts": { "api": "mail.example.com", "panel": "panel.example.com", "internal": "internal.example.com", "egress": "egress.example.net" },
  "core": "/home/me/src/mailstack",
  "pro": "/home/me/src/mailstack-pro",
  "config": "/home/me/mailstack/mailstack.json",
  "keyBackup": "/Volumes/OFFLINE/mailstack-content-keys.json",
  "license": { "product": "…", "host": "mail.example.com", "seller": "…", "jwksUrl": "https://…", "revocationUrl": "https://…" },
  "backup": { "endpoint": "https://s3.eu-central-003.backblazeb2.com", "bucket": "my-backups", "ageRecipient": "age1…" },
  "sesRegion": "eu-west-1",
  "secrets": {
    "cloudflare": "keystore:cloudflare_api_token",
    "api": { "SES_ACCESS_KEY_ID": "bw:Mailstack SES id", "SES_SECRET_ACCESS_KEY": "bw:Mailstack SES secret", "MAILSTACK_LICENSE": "file:/home/me/mailstack/license",
             "B2_KEY_ID": "bw:Mailstack register key id", "B2_APP_KEY": "bw:Mailstack register key" },
    "backup": { "B2_KEY_ID": "bw:Mailstack backup key id", "B2_APP_KEY": "bw:Mailstack backup key", "CLOUDFLARE_API_TOKEN": "bw:Mailstack D1 backup token" },
    "panel": { "PANEL_NTFY_URL": "env:MAILSTACK_NTFY_URL" }
  }
}
```

- `instance` names the API Worker and its D1, the panel Worker (`<instance>-panel`), the Tunnel, service tokens and the server directory `/opt/stacks/<instance>`. Use `mailstack` for an existing production Worker of that name.
- `config` is your Mailstack configuration (brands, logging, webhooks). The installer adds the `panel` client and the Pro extension; your other clients and webhook endpoints stay.
- `accessTeamDomain` (optional, profile b): your Access team host, e.g. `acme.cloudflareaccess.com`; without it the installer reads it from the account, which needs Access: Organizations Read on the token.
- `hosts.internal` (profiles a and b) is the internal API host in profile b and the reserved audience of the emergency route in profile a (core `docs/internal-api.md`). Put `hosts.egress` in a zone without webhook receivers: the egress refuses targets in its own zone.
- `secrets.api` is passed unchanged to the API (Worker secrets or `api.env`): add `TURNSTILE_SECRET`, SMTP settings (profile c, with `"sender": {"type": "smtp"}` in the config) or other provider settings there. `keyBackup` is the offline copy the core key generator verifies before printing any key.

## Commands

```bash
./local/deploy.sh mailstack --plan=~/mailstack/plan.json            # install, or apply changes
./local/deploy.sh mailstack --plan=~/mailstack/plan.json --update   # same, refusing when nothing is installed
./local/deploy.sh mailstack --plan=~/mailstack/plan.json --status   # API /health and the server containers
./local/deploy.sh mailstack --plan=~/mailstack/plan.json --invite   # another single-use admin invitation
./local/deploy.sh mailstack --plan=~/mailstack/plan.json --uninstall --yes
```

The first run generates the content, index and transit keys with the core `keys init` (after verifying your offline copy), the panel token, assertion, webhook and egress keyrings, the full `API_KEY` and an erasure register id, and writes the register's `genesis` and `head` to B2. Everything is kept in `~/.config/stackpilot/mailstack/<instance>/` (directory 0700, files 0600): back it up with your offline keys. Reruns reuse these values and every Cloudflare resource found by name; a service token whose secret is missing from the state is rotated, never duplicated. Each run ends with a first admin invitation until one was issued.

Order of an install or update: Cloudflare (Access, service tokens, Tunnel, DNS, D1) → Worker secrets with `wrangler secret bulk` → core `npm run release` (migrations, then the same build, health check) → panel Worker (`build:panel-worker`, D1 migrations, deploy with its secrets) → server: the configuration and a source context built by Pro's `container-context.mjs` are copied to `/opt/stacks/<instance>`, the egress firewall becomes the systemd unit `mailstack-egress-firewall` (with this host's public addresses as `EGRESS_DENY_CIDRS`), then the profile's services are built and started. A failed firewall stops before anything starts. One local egress per host; profile b can reuse an external egress (below).

`--uninstall --yes` stops the server stack and removes its volumes, local images, its own firewall unit and chains (only when the unit names this stack) and `/opt/stacks/<instance>`, then the Workers with their custom domains, D1 databases, Access applications, service tokens, Tunnel and its DNS records. Copies and the erasure register in B2 and your local state stay (backups are governed by the bucket lifecycle).

## After installing

- Panel: open the invitation, pass Access with your e-mail, register a passkey, import the content keyring (`content-private.json` from the state directory or your offline copy) in the browser.
- Sending: `API_KEY` in `generated.json` is the full key; create scoped keys with Mailstack Pro.
- SES events, Turnstile, Sellf hooks and restore procedures: core README, `docs/backup.md`, `docs/internal-api.md`; Pro README for the panel.

## Profile b with a shared or external egress

Keep the existing egress and its host firewall running. Add this optional block to the install plan; `hosts.egress` can be omitted:

```json
"externalEgress": {
  "url": "https://egress.example.net",
  "keys": "file:/home/me/mailstack/own-egress-keys.json",
  "accessClientId": "file:/home/me/mailstack/egress-access-id",
  "accessClientSecret": "file:/home/me/mailstack/egress-access-secret"
}
```

Before installation, generate a distinct order-signing keyring (`[{"kid":"instance-egress-1","key":"<32 random bytes, base64url>"}]`) and add those entries to the existing egress's `EGRESS_KEYS_FILE`, preserving every existing entry. Restart only that egress so it reads the new ring. The `keys` reference holds only the new installation's entries; the Worker signs with its first entry. Use the existing egress Access service token, or a separate token admitted by its operator. Keep that host in a zone without webhook receivers; its existing deny zones and host firewall still apply. Check `/ready` with Access and a signed test request before using webhooks.

The installer passes the referenced credentials to the new API. It creates no egress container, firewall, Access app, service token, DNS record or Tunnel route for the external URL. Reruns and uninstall leave those shared resources alone. Provisioning and retiring the shared key/token are the egress operator's responsibility: after removing this installation, remove only its signing entries (and a dedicated token if used), retaining all other entries. Do not remove the egress owner stack while dependents use it. This mode is supported only for profile b.
