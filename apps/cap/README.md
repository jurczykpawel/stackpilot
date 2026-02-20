# Cap - Open Source Loom Alternative

**Cap** lets you record your screen, edit and share videos in seconds. Great for:
- Recording tutorials for clients
- Asynchronous team communication
- Product demos
- Bug reports with screen recordings

> Project page: https://cap.so
> GitHub: https://github.com/CapSoftware/Cap

---

## Requirements

Cap is **resource-heavy**. It requires:

| Component | Description | RAM |
|-----------|------------|-----|
| cap-web | Main application | ~400-500 MB |
| MySQL | Database | ~300-500 MB |
| MinIO | S3 storage (optional) | ~200 MB |

**Recommendation:** 2GB RAM VPS or higher.

### Optimization for small VPS

To save resources:
1. **Use an external MySQL database (recommended)** - don't waste RAM on a local database. Cap only stores metadata (users, links) in the DB - the actual videos go to S3, so a small DB is more than enough.
2. **External S3** - use Cloudflare R2 (cheap!), AWS S3 or Backblaze B2 instead of local MinIO

---

## Installation

```bash
./local/deploy.sh cap
```

The script will ask for:
1. **Database mode** - external MySQL (recommended) or local
2. **Storage mode** - external S3 (recommended) or local MinIO
3. **Domain** - e.g. `cap.example.com`

---

## Recommended Storage Configuration

### Option 1: MinIO with StackPilot (simplest)
If you have MinIO installed as a separate app:
```bash
# First install MinIO
./local/deploy.sh minio --ssh=ALIAS

# Find credentials in:
ssh ALIAS "cat /opt/stacks/minio/.env"

# Then install Cap with external S3
S3_ENDPOINT=http://minio:9000 \
S3_ACCESS_KEY=admin \
S3_SECRET_KEY=<password-from-minio> \
S3_BUCKET=cap-videos \
./local/deploy.sh cap --ssh=ALIAS
```

### Option 2: Cloudflare R2 (cheapest for large volumes)
- Free 10GB/month
- No egress fees
- Endpoint: `https://<account-id>.r2.cloudflarestorage.com`
- Region: `auto`

### Option 3: AWS S3
- Pay-as-you-go
- Region: `eu-central-1` (Frankfurt) for low latency from Europe

### Option 4: Backblaze B2
- Cheap storage
- S3 API compatible

### Option 5: Local MinIO (built into Cap)
If you only need MinIO for Cap:
```bash
USE_LOCAL_MINIO=true ./local/deploy.sh cap --ssh=ALIAS
```
MinIO will start as a container in the same stack as Cap.

---

## Desktop Client

Cap has a desktop app for recording:
- **macOS:** https://cap.so/download
- **Windows:** https://cap.so/download

After installing the self-hosted version, configure the app to point to your own server.

---

## Management

### Logs
```bash
ssh ALIAS "docker logs -f cap-cap-web-1"
```

### Restart
```bash
ssh ALIAS "cd /opt/stacks/cap && docker compose restart"
```

### Update
```bash
ssh ALIAS "cd /opt/stacks/cap && docker compose pull && docker compose up -d"
```

---

## Security

After installation, **make sure to save** the generated keys:
- `NEXTAUTH_SECRET` - for user authentication
- `DATABASE_ENCRYPTION_KEY` - for encrypting data in the database

Without these keys you cannot recover data access after reinstallation!

---

## FAQ

**Q: How much disk space do I need?**
A: Depends on the number of recordings. 1 minute of HD video is ~50-100 MB. For many recordings, use external S3.

**Q: Can I use PostgreSQL instead of MySQL?**
A: No. Cap officially supports only MySQL 8.0.

**Q: How do I share a recording?**
A: After recording in the desktop app, Cap automatically uploads the video to your server and generates a sharing link.
