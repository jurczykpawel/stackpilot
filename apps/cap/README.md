# Cap - Open Source Loom Alternative

Record, edit and share video in seconds. Great for tutorials, async team communication, product demos, and bug reports.

> Project page: https://cap.so
> GitHub: https://github.com/CapSoftware/Cap

## Installation

```bash
./local/deploy.sh cap --ssh=ALIAS --domain-type=cloudflare --domain=cap.example.com
```

Cap requires a **domain** (used for HTTPS and video sharing links). It also requires a database and S3 storage — see options below.

### Option A: Local MySQL + Local MinIO (simplest)

```bash
MYSQL_ROOT_PASS=secret \
USE_LOCAL_MINIO=true \
./local/deploy.sh cap --ssh=ALIAS --domain-type=cloudflare --domain=cap.example.com
```

### Option B: External MySQL + External S3

```bash
DB_HOST=mysql.example.com DB_PORT=3306 DB_NAME=cap \
DB_USER=myuser DB_PASS=secret \
S3_ENDPOINT=https://xxx.r2.cloudflarestorage.com \
S3_PUBLIC_URL=https://cdn.example.com \
S3_REGION=auto S3_BUCKET=cap-videos \
S3_ACCESS_KEY=xxx S3_SECRET_KEY=yyy \
./local/deploy.sh cap --ssh=ALIAS --domain-type=cloudflare --domain=cap.example.com
```

### Option C: Separate MinIO app (recommended)

```bash
# First install MinIO as a standalone app:
./local/deploy.sh minio --ssh=ALIAS

# Get credentials:
ssh ALIAS 'cat /opt/stacks/minio/.env'

# Then install Cap pointing to it:
S3_ENDPOINT=http://cap-minio:9000 \
S3_ACCESS_KEY=admin \
S3_SECRET_KEY=<password-from-minio-env> \
S3_BUCKET=cap-videos \
./local/deploy.sh cap --ssh=ALIAS --domain-type=cloudflare --domain=cap.example.com
```

## Requirements

- **RAM:** ~1.5-2GB+ (cap-web 512M + MySQL 512M + MinIO 256M when all bundled)
- **Disk:** ~1.5GB image (`cap-web`) + ~4GB total with MySQL and MinIO images
- **Port:** 3000 (main app)
- **Database:** MySQL 8.0 only (PostgreSQL not supported)

### Local MinIO ports (when `USE_LOCAL_MINIO=true`)

| Port | Service |
|------|---------|
| 3000 | Cap web app |
| 3902 | MinIO S3 API (public video access via `https://<domain>:3902`) |
| 3903 | MinIO Console (localhost only) |

> **Note:** When using local MinIO, port 3902 must be reachable from the internet — Cap's desktop app fetches videos from `https://<domain>:3902`. Configure your firewall/proxy accordingly or use an external S3 provider instead.

## Recommended Storage

| Option | Cost | Notes |
|--------|------|-------|
| Local MinIO (bundled) | Free | Needs open port 3902 or proxy |
| Cloudflare R2 | Free 10GB/mo, no egress | Best for production |
| AWS S3 | Pay-as-you-go | Region `eu-central-1` for EU |
| Backblaze B2 | Cheap | S3 API compatible |

## After Installation

1. Open `https://<domain>` to get started
2. Install the Cap desktop app: https://cap.so/download
3. In the desktop app, point to your self-hosted server

**Save these keys** — without them you cannot recover access after reinstallation:
- `NEXTAUTH_SECRET` — user authentication
- `DATABASE_ENCRYPTION_KEY` — data encryption

## Management

```bash
# Logs
ssh ALIAS "docker logs -f cap-cap-web-1"

# Restart
ssh ALIAS "cd /opt/stacks/cap && docker compose restart"

# Update
ssh ALIAS "cd /opt/stacks/cap && docker compose pull && docker compose up -d"
```

## FAQ

**Q: How much disk space per recording?**
A: ~50-100MB per minute of HD video. Use external S3 for large volumes.

**Q: Can I use PostgreSQL?**
A: No. Cap officially supports MySQL 8.0 only.

**Q: How does sharing work?**
A: After recording in the desktop app, Cap automatically uploads the video and generates a sharing link.
