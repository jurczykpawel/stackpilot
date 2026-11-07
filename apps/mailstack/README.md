# Mailstack

Form-to-email and transactional email API with an encrypted delivery log, plus the
licensed Mailstack Pro panel, webhooks and offsite backups. The caller decides what
to send and when. The installer supports three profiles:

| Profile | Cloudflare | Your server |
| --- | --- | --- |
| **a** | API Worker + D1, panel Worker + D1, Access on the panel and egress hosts | `cloudflared`, `egress` (webhooks leave here), `backup`, host firewall |
| **b** | API Worker + D1, Access on the internal API, panel and egress hosts | panel, `cloudflared`, `egress`, `backup`, host firewall |
| **c** | Tunnel and Access only | API (Node + SQLite), panel, `cloudflared`, `backup` |

Profile (a) puts both application services on Workers; it still needs a server
for egress and backups. Profile (c) puts compute and databases on the VPS; the
supplied ingress still uses Cloudflare DNS, Tunnel and Access. No Cloudflare
Container is used. In profile (b), `externalEgress` can replace the local egress.

Nothing publishes a port: the panel and (in profile c) the API are reached through a Cloudflare Tunnel; the panel host admits only the owner's e-mail through Cloudflare Access, then a passkey.

## Requirements

- On your computer: Node.js 24+, `ssh` access to the server (root or passwordless `sudo`), clean checkouts of `mailstack` and `mailstack-pro` with `npm ci` done, and the release guard satisfied for profiles a and b: an `instance` named `mailstack` (production) needs `HEAD` equal to `origin/main` or a tag reachable from it; any other instance needs only clean checkouts.
- On the server: Linux with Docker Compose v2.24.4+, `curl`, `openssl`, `ip`, systemd and iptables (profiles a and b).
- Cloudflare: the hostnames in zones of this account; an API token with Workers Scripts, D1, Workers Custom Domains, Access (apps, service tokens, organization read), Cloudflare Tunnel and DNS edit; a second token with **only D1 Write** for the backup service. D1 Read is insufficient: the export endpoint locks the database and requires Write permission (see [Cloudflare export authentication errors](https://developers.cloudflare.com/d1/observability/debug-d1/#error-10000-and-token-permissions)). Each API Worker uses one Cron Trigger (five per account on Workers Free); the
  panel Worker uses none. Cloudflare still applies the documented 10 ms Free CPU
  limit. D1 daily read/write and account storage allowances are shared with every
  other application in the account; a second panel database does not add quota.
  See [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
  and [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/).
- Backups: a B2 bucket, two runtime application keys (the `secrets.api` register key needs `readFiles`+`writeFiles`+`listFiles` for the first install, because the installer initializes the register with that key; afterwards you may replace it with a `readFiles`+`writeFiles` key. The backup key needs `writeFiles` only; see the core `docs/backup.md`) and the owner's `age` public key. The private `age` key never leaves your computer.
- An HTTPS ntfy topic referenced by `secrets.panel.PANEL_NTFY_URL` for panel alerts.
- For SES: a verified sender identity in `sesRegion` and production access (out of the SES sandbox) to send to arbitrary recipients.
- A Mailstack Pro license (Sellf) for the panel.

## Install plan

Keep the plan outside any repository. Secrets are references, never values: `env:NAME`, `file:/path`, `bw:<Vaultwarden item>` (password field) or `keystore:<name>` (`./local/keys.sh`).

```json
{
  "instance": "mailstack",
  "profile": "a",
  "ssh": "vps",
  "accountId": "00000000000000000000000000000000",
  "ownerEmail": "owner@example.com",
  "hosts": { "api": "mail.example.com", "panel": "panel.example.com", "internal": "internal.example.com", "egress": "egress.example.net" },
  "core": "/home/me/src/mailstack",
  "pro": "/home/me/src/mailstack-pro",
  "config": "/home/me/mailstack/mailstack.json",
  "keyBackup": "/Volumes/OFFLINE/mailstack-content-keys.json",
  "license": { "product": "mailstack-pro", "host": "mail.example.com", "seller": "your-issuer", "jwksUrl": "https://license.example.com/jwks", "revocationUrl": "https://license.example.com/revoked" },
  "backup": { "endpoint": "https://s3.eu-central-003.backblazeb2.com", "bucket": "my-backups", "ageRecipient": "age1…" },
  "sesRegion": "eu-west-1",
  "secrets": {
    "cloudflare": "keystore:cloudflare_api_token",
    "cloudflareZeroTrust": "keystore:cloudflare_zero_trust_token",
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

## Choose and validate a profile

Replace every example account, path, hostname, license setting, age recipient and
secret reference before installation. `backup.ageRecipient` must be the actual
public `age1...` key, not the abbreviated example. Set `sesConfigurationSet` when
using SES event tracking and include `events.ses` allowlists in your external core
configuration. SMTP is available only in profile (c).

- **a:** keep all four host entries. `internal` is a reserved recovery audience,
  not a permanent API route. The API and panel need separate D1 databases.
- **b:** set `profile` to `b`; the panel uses `hosts.internal` with Access service
  authentication. Use `externalEgress` below to share an existing egress, otherwise
  retain `hosts.egress` and provision its firewall.
- **c:** set `profile` to `c`; `hosts.internal` and `hosts.egress` are unnecessary.
  API and panel use separate SQLite volumes. The API reaches public webhooks
  directly with its Node transport, so no egress service is started.

`secrets.cloudflareZeroTrust` is optional: when absent, `secrets.cloudflare` must
also have Access/Tunnel permissions. When present it separates those operations
from Worker/D1/DNS management. The backup D1 token remains a third token with only D1 Write
for profiles (a)/(b). Supply `accessTeamDomain` in profile (b) to avoid the Access
organization-read lookup when the token lacks that permission.

From the Stackpilot checkout, validate the plan without resolving secrets or
contacting a provider (set `PLAN_FILE` to its absolute path):

```sh
PLAN_FILE="$HOME/mailstack/plan.json" node --input-type=module <<'JS'
import { readFileSync } from 'node:fs';
import { readPlan } from './apps/mailstack/lib.mjs';
readPlan(JSON.parse(readFileSync(process.env.PLAN_FILE, 'utf8')));
console.log('Install plan OK');
JS
```

Validate the core config separately with
`node scripts/mailstack.ts config check /absolute/path/mailstack.json` from the
core checkout. `readPlan` checks plan shape only; it does not validate the license,
secret contents, provider permissions, source paths or actual resource readiness.
The installer has no `--dry-run` mode. Install/update commands below create or
change external resources.

## Commands

```bash
./local/deploy.sh mailstack --plan="$HOME/mailstack/plan.json"            # install, or apply changes
./local/deploy.sh mailstack --plan="$HOME/mailstack/plan.json" --update   # same, refusing when nothing is installed
./local/deploy.sh mailstack --plan="$HOME/mailstack/plan.json" --status   # API /health and the server containers
./local/deploy.sh mailstack --plan="$HOME/mailstack/plan.json" --invite   # another single-use admin invitation
./local/deploy.sh mailstack --plan="$HOME/mailstack/plan.json" --uninstall --yes
```

On first installation the key generator creates the private content file, and
installation stops until its offline copy at `keyBackup` can be verified. Rerun
with that copy available; no deployable key assignments are released before this
check. The installer then generates the content, index and transit keys with the core `keys init` (after verifying your offline copy), the panel token, assertion, webhook and egress keyrings, the full `API_KEY` and an erasure register id, and writes the register's `genesis` and `head` to B2. Everything is kept in `~/.config/stackpilot/mailstack/<instance>/` (directory 0700, files 0600): back it up with your offline keys. Reruns reuse these values and every Cloudflare resource found by name; a service token whose secret is missing from the state is rotated, never duplicated. Each run ends with a first admin invitation until one was issued.

Order of an install or update: Cloudflare (Access, service tokens, Tunnel, DNS, D1) → Worker secrets with `wrangler secret bulk` → core `npm run release` (migrations, then the same build, health check) → panel Worker (`build:panel-worker`, D1 migrations, deploy with its secrets) → server: the configuration and a source context built by Pro's `container-context.mjs` are copied to `/opt/stacks/<instance>`, the egress firewall becomes the systemd unit `mailstack-egress-firewall` (with this host's public addresses as `EGRESS_DENY_CIDRS`), then the profile's services are built and started. A failed firewall stops before anything starts. One local egress per host; profile b can reuse an external egress (below).

`--uninstall --yes` stops the server stack and removes its volumes, local images, its own firewall unit and chains (only when the unit names this stack) and `/opt/stacks/<instance>`, then the Workers with their custom domains, D1 databases, Access applications, service tokens, Tunnel and its DNS records. Copies and the erasure register in B2 and your local state stay (backups are governed by the bucket lifecycle).

## After installing

- Allow several minutes for new Cron Triggers to propagate (up to 15). A healthy
  API alone does not prove the cron or egress works. UTC minute 17 is retention
  only; other minutes drain work. Keep cron enabled to complete erase and queued
  work. `202` accepts an erase job: wait for `done`, then check the result.
- Worker health checks require `store: ok` plus matching core and Pro SHAs.
  Node checks storage but can report `commit: dev`; retain source/image IDs.
- Check the `backup` container logs and download/decrypt one B2 copy locally after installation. Installer success and `--status` do not prove a working backup; an insufficient D1 token can leave `backup` restarting while API and panel health checks pass. Never put the broader deployment token in `backup.env`.
- Use a separate B2 bucket for each independent profile (c) installation: SQLite copies use `mailstack/mailstack-YYYYMMDD.db.age`, without the instance name. Sharing a bucket can replace another installation's same-day copy.
- Back up local installation state and all key generations separately from database
  copies. Retain the complete B2 erasure register for its lifetime; never apply the
  database-copy lifecycle rule to that prefix. Restore into isolated databases and
  reapply registered erasures before reopening traffic (core/Pro restore procedures).

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

## Update and cleanup boundaries

A rerun reuses recorded keys and resources, but profiles (a)/(b) still upload new
Worker versions even for the same source SHA. Core releases upgrade the database
before deploy; do not run example-generating tests between setup and release.
Record immutable source and image references and a consistent backup before updating.
A profile change is not an automatic migration of D1/SQLite data: use a separate
instance and the documented restore procedure.

`--status` reads API health and server containers; it does not verify feature
capabilities, provider delivery, erasure completion or backup readability.
`--uninstall --yes` is destructive for this instance's Worker/D1 and server data.
It preserves local protected state, offline keys, B2 copies and the erasure register.
Remove those separately only under their retention/recovery policy. For a shared
egress, retire this installation's signing entries and dedicated token with its
operator after uninstall; never remove the owner's firewall or Tunnel while other
installations depend on them. Do not run global Docker prune for cleanup.
