# MinIO - S3-Compatible Object Storage

Self-hosted storage compatible with the Amazon S3 API.

## Requirements

- **RAM**: ~256MB
- **Disk**: Depends on the amount of stored files
- **Plan**: 1GB+ RAM VPS (basic is sufficient)

## Installation

```bash
./local/deploy.sh minio --ssh=ALIAS --domain=s3.example.com
```

### Optional variables

```bash
MINIO_ROOT_USER=admin \
MINIO_ROOT_PASSWORD=supersecret \
DEFAULT_BUCKET=myfiles \
./local/deploy.sh minio --ssh=ALIAS
```

## Ports

| Port | Service |
|------|---------|
| 9000 | S3 API (AWS S3 compatible) |
| 9001 | Console (Web UI) |

## Usage with Other Applications

### Cap (video recordings)

In `apps/cap/install.sh`:
```bash
S3_ENDPOINT=http://minio:9000
S3_ACCESS_KEY=admin
S3_SECRET_KEY=<password from /opt/stacks/minio/.env>
S3_BUCKET=cap-videos
```

### Typebot (file uploads)

```bash
S3_ENDPOINT=http://minio:9000
S3_ACCESS_KEY=admin
S3_SECRET_KEY=<password>
S3_BUCKET=typebot-uploads
```

### Your own application

```javascript
// Node.js with AWS SDK
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

## Managing Buckets

### Via Web Console

1. Open https://s3.example.com (or http://localhost:9001)
2. Log in with credentials from `.env`
3. "Create Bucket" -> enter name

### Via CLI (mc)

```bash
# Inside the container
docker exec minio mc alias set local http://localhost:9000 admin <password>
docker exec minio mc mb local/new-bucket
docker exec minio mc ls local/
```

### Via API (curl)

```bash
# Creating a bucket
curl -X PUT http://localhost:9000/new-bucket \
  -H "Authorization: AWS admin:<signature>"
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

### Container does not start

```bash
docker logs minio
```

### Out of disk space

```bash
df -h
# Remove unnecessary files or expand disk
```

### Permission issues

```bash
sudo chown -R 1000:1000 /opt/stacks/minio/data
```

## Links

- [MinIO Documentation](https://min.io/docs/minio/linux/index.html)
- [S3 API Reference](https://docs.aws.amazon.com/AmazonS3/latest/API/Welcome.html)
