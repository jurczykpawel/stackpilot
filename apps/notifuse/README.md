# Notifuse

Self-hosted newsletter, transactional email and automation platform (Go + React), with a bundled dedicated PostgreSQL 17 database. Uses the upstream prebuilt `notifuse/notifuse:v42.1` image; no build runs on the VPS.

```bash
./local/deploy.sh notifuse --ssh=vps --domain-type=cloudflare --domain=mail.example.com --yes
./local/deploy.sh notifuse --ssh=vps --domain-type=local --yes
```

The default host port is **8081**. For local access, forward it with `ssh -L 8081:localhost:8081 vps` and open `http://localhost:8081/console`. Domain setup uses StackPilot's existing deployment flow. HTTP binds to localhost except for Cytrus, which requires direct access. PostgreSQL and the optional SMTP bridge have no published ports.

The installer generates `SECRET_KEY` and `DB_PASSWORD` once in `/opt/stacks/notifuse/.env` (mode 600). Reinstalling preserves them and the persistent named volumes (`postgres-data`, `notifuse-data`); the API endpoint follows the domain passed by `deploy.sh`. An incomplete existing `.env` stops the installer instead of replacing keys. Back up the configuration and both volumes together. Never replace `SECRET_KEY` on its own after saving credentials.

Open `/console` and complete the upstream setup wizard: root email and SMTP for system emails. Then configure an email sending provider in the workspace. Installing does not send email or configure mail-provider DNS. Configure SPF, DKIM and DMARC according to the chosen provider. The application needs PostgreSQL administrative credentials because each workspace gets its own database; StackPilot bundles an isolated PostgreSQL instance for this reason.

The compose memory limits are 512 MiB for Notifuse and 256 MiB for PostgreSQL; allow additional RAM for the OS and other applications. The installer waits for both services to become healthy and verifies `/healthz` on the published port before returning success.

To update, rerun the deployment after reviewing upstream changes and backing up. To select a different application image when running the installer on-server, set `IMAGE_TAG`; do not change the PostgreSQL major version without migrating its data.

Notifuse v40+ uses Business Source License 1.1 with some paid capabilities; a licence key is optional for the free tier. See the upstream [installation guide](https://docs.notifuse.com/self-hosting/installation), [environment configuration](https://github.com/Notifuse/notifuse/blob/main/env.example), and [licensing](https://github.com/Notifuse/notifuse/blob/main/LICENSING.md).
