# MinIO - S3-Compatible Object Storage

Self-hosted storage kompatybilny z Amazon S3 API.

## Wymagania

- **RAM**: ~256MB
- **Dysk**: Zależy od ilości przechowywanych plików
- **Plan**: Mikrus 2.1+ (wystarczy podstawowy)

## Instalacja

```bash
./local/deploy.sh minio --ssh=ALIAS --domain=s3.example.com
```

### Opcjonalne zmienne

```bash
MINIO_ROOT_USER=admin \
MINIO_ROOT_PASSWORD=supersecret \
DEFAULT_BUCKET=myfiles \
./local/deploy.sh minio --ssh=ALIAS
```

## Porty

| Port | Usługa |
|------|--------|
| 9000 | S3 API (kompatybilny z AWS S3) |
| 9001 | Console (Web UI) |

## Użycie z innymi aplikacjami

### Cap (nagrania wideo)

W `apps/cap/install.sh`:
```bash
S3_ENDPOINT=http://minio:9000
S3_ACCESS_KEY=admin
S3_SECRET_KEY=<hasło z /opt/stacks/minio/.env>
S3_BUCKET=cap-videos
```

### Typebot (uploady plików)

```bash
S3_ENDPOINT=http://minio:9000
S3_ACCESS_KEY=admin
S3_SECRET_KEY=<hasło>
S3_BUCKET=typebot-uploads
```

### Własna aplikacja

```javascript
// Node.js z AWS SDK
const s3 = new S3Client({
  endpoint: "http://minio:9000",
  credentials: {
    accessKeyId: "admin",
    secretAccessKey: "<hasło>"
  },
  forcePathStyle: true,
  region: "us-east-1"
});
```

## Zarządzanie bucketami

### Przez Web Console

1. Otwórz https://s3.example.com (lub http://localhost:9001)
2. Zaloguj się credentials z `.env`
3. "Create Bucket" → podaj nazwę

### Przez CLI (mc)

```bash
# Wewnątrz kontenera
docker exec minio mc alias set local http://localhost:9000 admin <hasło>
docker exec minio mc mb local/nowy-bucket
docker exec minio mc ls local/
```

### Przez API (curl)

```bash
# Tworzenie bucketu
curl -X PUT http://localhost:9000/nowy-bucket \
  -H "Authorization: AWS admin:<signature>"
```

## Backup

Dane MinIO są przechowywane w `/opt/stacks/minio/data/`.

```bash
# Backup
tar -czf minio-backup.tar.gz /opt/stacks/minio/data/

# Restore
tar -xzf minio-backup.tar.gz -C /
docker compose -f /opt/stacks/minio/docker-compose.yaml restart
```

## Troubleshooting

### Kontener nie startuje

```bash
docker logs minio
```

### Brak miejsca na dysku

```bash
df -h
# Usuń niepotrzebne pliki lub rozszerz dysk
```

### Problemy z uprawnieniami

```bash
sudo chown -R 1000:1000 /opt/stacks/minio/data
```

## Linki

- [MinIO Documentation](https://min.io/docs/minio/linux/index.html)
- [S3 API Reference](https://docs.aws.amazon.com/AmazonS3/latest/API/Welcome.html)
