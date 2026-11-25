# Plunk

Self-hosted email platform using the upstream `ghcr.io/useplunk/plunk` image, PostgreSQL, Redis, MinIO and ntfy. Nothing is built on the VPS.

## Install

Plunk requires AWS SES credentials at startup. Save these in `~/.config/stackpilot/plunk.env` **on the target server**, with mode `600`:

```bash
AWS_SES_REGION=eu-west-1
AWS_SES_ACCESS_KEY_ID=your-access-key
AWS_SES_SECRET_ACCESS_KEY=your-secret-key
SES_CONFIGURATION_SET=your-existing-configuration-set
```

Then use the normal StackPilot deployment flow:

```bash
./local/deploy.sh plunk --ssh=vps --domain-type=cloudflare --domain=mail.example.com --yes
```

Caddy, Cloudflare DNS, TLS and Cytrus registration are handled by StackPilot. The installer only configures its containers. The default port is `3560`; proxy/local deployments bind to loopback and Cytrus binds to all interfaces.

Without a domain, open an SSH tunnel:

```bash
./local/deploy.sh plunk --ssh=vps --domain-type=local --yes
ssh -L 3560:localhost:3560 vps
```

New installations set `DISABLE_SIGNUPS=true`. To create the first account, deploy in local mode with the SSH tunnel above, temporarily set `DISABLE_SIGNUPS=false` in `/opt/stacks/plunk/.env` and redeploy in local mode. Open `http://localhost:3560/auth/signup` and create your account. Immediately set `DISABLE_SIGNUPS=true` and redeploy locally before assigning a public domain. Existing `.env` values are preserved, so upgrading an older installation does not change its signup policy. The upstream app does not automatically close signups after the first account.

## Routing and storage

The nginx gateway uses Docker DNS to refresh backend addresses, so API, dashboard and upload routes recover after container recreation. Reinstalling validates and reloads an already running gateway before waiting for readiness. This uses nginx's open-source `resolve` support (1.27.3+); the installer pulls the current `nginx:alpine` image.

One domain serves the dashboard at `/`, API at `/api/` (e.g. `/api/health`), and uploaded assets at `/uploads/`. A bundled nginx gateway removes `/api/` before proxying to the API. Explicit upstream `API_URI` and `DASHBOARD_URI` values keep browser requests on the same origin. PostgreSQL, Redis and MinIO persist in named Docker volumes and are not published on host ports.

Plunk's upstream SMTP relay ports are not published; use the HTTP API to send mail. The bundled marketing landing page and documentation server are not exposed.

Secrets persist in `/opt/stacks/plunk/.env` (mode `600`); repeat installs refresh URLs without rotating database, JWT or storage credentials. Back up this file and the three named volumes. To change SES credentials after installation, edit this `.env`; the bootstrap configuration file only supplies the first installation.

## Requirements

Budget approximately 2 GB of available RAM and 6 GB of disk for the complete stack; actual usage depends on image version and workload. Container memory limits total about 1.7 GB. Use a larger VPS for sustained campaigns.

AWS SES must have a verified sending domain and the configured configuration set. Sandbox recipient restrictions and production access remain AWS account settings. Installation/readiness checks do not send email and do not prove delivery.

`IMAGE_TAG` can pin a published upstream image version when running the installer directly. Standard `deploy.sh` deploys the default upstream `latest` image.

Upstream references: [Docker deployment](https://github.com/useplunk/plunk/blob/next/apps/wiki/content/docs/self-hosting/docker.mdx), [environment variables](https://github.com/useplunk/plunk/blob/next/apps/wiki/content/docs/self-hosting/environment-variables.mdx), [Compose](https://github.com/useplunk/plunk/blob/next/docker-compose.yml). StackPilot's single-origin gateway adapts upstream's default subdomain routing.

Gateway regression test (local Docker): `bash tests/e2e/plunk-gateway.sh`. It replaces a backend with a different IP and checks all three URI routes without restarting the gateway.
