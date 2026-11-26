# MinIO - S3-Compatible Object Storage

Self-hosted storage compatible with the Amazon S3 API. Use it for file storage, backups, and media uploads.

## Installation

```bash
./local/deploy.sh minio --ssh=ALIAS --domain-type=cloudflare --domain=s3.example.com
```

### Optional variables

```bash
MINIO_ROOT_USER=admin \
MINIO_ROOT_PASSWORD=supersecret \
DEFAULT_BUCKET=myfiles \
./local/deploy.sh minio --ssh=ALIAS
```

`PORT` sets the Console port (default 9001, the one the domain points at), `API_PORT` the S3 API port (default 9000).

## Image

The installer uses `pgsty/silo:RELEASE.2026-11-12T00-00-00Z`, the same image as the MinIO bundled with Cap and Plunk.

- MinIO, Inc. stopped the community distribution: the `minio/minio` image is gone from Docker Hub and the GitHub repository is archived (last release October 2025). Its successor, AIStor, is a separately licensed product.
- [Silo](https://github.com/pgsty/silo) (Pigsty, formerly `pgsty/minio`) is a maintained fork of the open-source MinIO server (AGPLv3) with security fixes, the full web console and multi-arch images. It keeps the `MINIO_*` variables, the `server` command, the S3 API and the data format, and ships the client as `mc` and `mcli`.
- The tag is pinned so a re-deploy does not change the server version. To upgrade, read the [release notes](https://github.com/pgsty/silo/releases), change the tag in `/opt/stacks/minio/docker-compose.yaml` and run `sudo docker compose up -d` there.

## Requirements

- **RAM:** ~256MB
- **Disk:** ~250MB image + stored files
- **Port:** 9000 (S3 API), 9001 (Console Web UI)

> When deployed **with a domain**, Caddy exposes the **Console (port 9001)** at `https://<domain>`.
> Both ports are bound to `127.0.0.1` (all interfaces only with `--domain-type=cytrus`). The S3 API (port 9000) needs a separate subdomain behind Caddy, an SSH tunnel, or a shared Docker network.

## Ports

| Port | Service |
|------|---------|
| 9000 | S3 API (AWS S3 compatible) |
| 9001 | Console (Web UI) |

## After Installation

### Access the Console

```bash
# With domain (Console exposed via Caddy):
https://s3.example.com

# Without domain (SSH tunnel):
ssh -L 9001:localhost:9001 ALIAS
# then open http://localhost:9001
```

### Get credentials

```bash
ssh ALIAS 'cat /opt/stacks/minio/.env'
```

### Create a bucket via CLI

```bash
# Get password from .env first:
ssh ALIAS 'cat /opt/stacks/minio/.env'

# Then inside the container:
docker exec minio mc alias set local http://localhost:9000 admin <password-from-env>
docker exec minio mc mb local/bucket-name
docker exec minio mc ls local/
```

## Usage with Other Applications

### Cap (video recordings)

```bash
S3_ENDPOINT=http://cap-minio:9000
S3_ACCESS_KEY=admin
S3_SECRET_KEY=<password from: ssh ALIAS 'cat /opt/stacks/minio/.env'>
S3_BUCKET=cap-videos
```

### Typebot (file uploads)

```bash
S3_ENDPOINT=http://minio:9000
S3_ACCESS_KEY=admin
S3_SECRET_KEY=<password from: ssh ALIAS 'cat /opt/stacks/minio/.env'>
S3_BUCKET=typebot-uploads
```

### Node.js (AWS SDK)

```javascript
const s3 = new S3Client({
  endpoint: "http://minio:9000",
  credentials: {
    accessKeyId: "admin",
    secretAccessKey: "<password>"
  },
  forcePathStyle: true,
  region: "us-east-1"
});
```

## Backup

MinIO data is stored in `/opt/stacks/minio/data/`.

```bash
# Backup
tar -czf minio-backup.tar.gz /opt/stacks/minio/data/

# Restore
tar -xzf minio-backup.tar.gz -C /
docker compose -f /opt/stacks/minio/docker-compose.yaml restart
```

## Troubleshooting

```bash
# Container logs
docker logs minio

# Disk space
df -h

# Permission issues
sudo chown -R 1000:1000 /opt/stacks/minio/data
```

## Links

- [MinIO Documentation](https://min.io/docs/minio/linux/index.html)
- [S3 API Reference](https://docs.aws.amazon.com/AmazonS3/latest/API/Welcome.html)
