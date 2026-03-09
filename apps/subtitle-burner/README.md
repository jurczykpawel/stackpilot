# Subtitle Burner - Animated Subtitle Burner for Video

Create, style, and burn animated subtitles onto video. Visual editor, 8 templates, AI transcription, server-side rendering (FFmpeg).

## Installation

```bash
./local/deploy.sh subtitle-burner --ssh=ALIAS --domain-type=cloudflare --domain=subtitles.example.com
```

### Database options

```bash
# Default: bundled PostgreSQL (zero config)
./local/deploy.sh subtitle-burner --ssh=ALIAS --domain-type=cloudflare --domain=subtitles.example.com

# External PostgreSQL
./local/deploy.sh subtitle-burner --ssh=ALIAS --db-source=custom --domain-type=cloudflare --domain=subtitles.example.com
```

## Requirements

- **RAM:** 2GB minimum (build + runtime: web 512M + worker 512M + nginx 64M + minio 256M + optional postgres 256M)
- **Disk:** ~900MB image (Next.js + Bun + FFmpeg + Nginx + MinIO)
- **Port:** 3000
- **Database:** PostgreSQL 16 (bundled by default, or external via `--db-source=custom`)
- **Redis:** Shared (`redis-shared` container on host, auto-installed if not present)

## Stack

| Container | Image | RAM | Role |
|-----------|-------|-----|------|
| nginx | nginx:alpine | 64M | Reverse proxy |
| web | Build (Next.js/Bun) | 512M | Main application |
| worker | Build (Bun + FFmpeg) | 512M | Video rendering |
| minio | minio/minio | 256M | Object storage |
| postgres *(bundled)* | postgres:16-alpine | 256M | Database (optional, skipped with `--db-source=custom`) |

> **Note:** Redis is NOT bundled in this stack. A shared `redis-shared` container is auto-installed on the host and used by all apps that need it.

## After Installation

1. Open the app in the browser and register an account
2. Upload a video and test subtitle burning
3. (Optional) Configure SMTP for magic link auth:

```bash
ssh ALIAS 'nano /opt/stacks/subtitle-burner/.env'
# Set: SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, EMAIL_FROM
ssh ALIAS 'cd /opt/stacks/subtitle-burner && docker compose restart web'
```

## Source

https://github.com/jurczykpawel/subtitle-burner
