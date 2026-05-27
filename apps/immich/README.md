# Immich

Self-hosted photo and video management — the Google Photos alternative.
Face recognition, CLIP semantic search, mobile backup, sharing.

## Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 4 GB (server 1 GB + ML 1 GB + postgres 1.5 GB for geodata import + OS) | 4 GB |
| Disk (OS + app) | 40 GB | 40 GB |
| Disk (photos) | Separate recommended | Separate |
| CPU | 2 vCPU | 2+ vCPU |

**Suitable VPS:** Mikrus 3.5 (4 GB, 40 GB, 197 PLN/yr) or Hetzner CAX11 (4 GB, 40 GB, €4.49/mo as of April 2026 — better hardware, ARM64 Ampere, NVMe, but ~30% more expensive than Mikrus).

For large libraries (200+ GB), add external storage via Immich's external library feature or S3 storage.

## Ports

| Service | Port |
|---------|------|
| Web UI + API | 2283 |

## Deploy

```bash
# With Cloudflare domain
./local/deploy.sh immich --ssh=vps --domain-type=cloudflare --domain=photos.example.com

# With Cytrus free subdomain (e.g. immich.byst.re)
./local/deploy.sh immich --ssh=vps --domain-type=cytrus

# Local only (SSH tunnel)
./local/deploy.sh immich --ssh=vps --domain-type=local --yes
```

> **Cytrus note:** The domain is registered automatically AFTER Immich is healthy (the installer waits for `/api/server/ping` to respond before calling the Cytrus API). Never register a Cytrus domain manually while the app is still starting up — the domain becomes permanently broken (502, cannot be deleted via API, only via Mikrus panel).

## Post-install

1. Open the URL and **register the first account** — it automatically becomes admin.
2. Install the Immich app on **iOS or Android**, point it to your server URL.
3. Enable automatic backup in the mobile app (Settings → Backup).
4. ML models (~1-2 GB) download on first use. Face recognition activates after first upload.

## Migrating from Google Photos

1. Use [Google Takeout](https://takeout.google.com/) to export your photos.
2. In Immich: Administration → Jobs → Import from Google Photos.

## Storage: photos on external disk / S3

For libraries larger than 20 GB, edit `.env` on the server:

```bash
# Local external disk
UPLOAD_LOCATION=/mnt/photos

# Or configure S3/B2 in Immich UI:
# Administration → Storage → Storage Template
```

## Backup

Photos should be backed up separately from the Immich stack.

**Recommended:** `restic` → S3 Glacier Deep Archive (write-once archive, ~$0.001/GB/mo).

```bash
# Back up photos directory
restic -r s3:s3.amazonaws.com/my-bucket/immich backup /opt/stacks/immich/library

# Back up postgres
docker exec immich_postgres pg_dumpall -U postgres | gzip > immich-db.sql.gz
restic -r s3:s3.amazonaws.com/my-bucket/immich backup immich-db.sql.gz
```

## Update

```bash
ssh <server>
cd /opt/stacks/immich
docker compose pull
docker compose up -d
```

## Useful commands

```bash
# Logs
docker compose logs -f
docker compose logs -f immich-machine-learning

# Status
docker compose ps

# DB backup (manual)
docker exec immich_postgres pg_dumpall -U postgres > /tmp/immich-db.sql

# Restart
docker compose restart immich-server
```
