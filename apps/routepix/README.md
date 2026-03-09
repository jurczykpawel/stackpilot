# RoutePix - Travel Route Visualizer from Geotagged Photos

Visualize travel routes from geotagged photos. Upload photos → EXIF extraction → interactive map with markers and route. Optional AI scene recognition.

## Installation

```bash
./local/deploy.sh routepix --ssh=ALIAS --domain-type=cloudflare --domain=routes.example.com
```

## Requirements

- **RAM:** ~512MB (1 container, memory limit: 512M)
- **Disk:** ~600MB image (Node.js 22 + Next.js standalone + better-sqlite3 + vips) + user photo uploads
- **Port:** 3000
- **Database:** SQLite (bundled in container, zero config)

## Stack

| Component | Technology |
|-----------|------------|
| Frontend | Next.js + Tailwind + Leaflet |
| Backend | Next.js API Routes + Prisma |
| Database | SQLite (embedded, no external DB needed) |
| Images | sharp + vips |
| Auth | Magic links (JWT) |

## After Installation

1. Configure SMTP (required for magic link login):

```bash
ssh ALIAS 'nano /opt/stacks/routepix/.env'
# Set: SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM
ssh ALIAS 'cd /opt/stacks/routepix && docker compose restart'
```

2. Open the app → request magic link to `ADMIN_EMAIL`
3. Upload geotagged photos or import from Google Photos

### Optional integrations

```bash
# AI scene recognition (free tier available):
AI_GROQ_API_KEY=your-key

# Google Photos import:
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...

# Road-snapping (uses public OSRM by default):
OSRM_BASE_URL=https://router.project-osrm.org
```

## Source

https://github.com/jurczykpawel/routepix
