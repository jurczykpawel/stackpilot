# 🔥 Supabase Self-Hosted

Open-source Firebase alternative: PostgreSQL, Auth, Storage, Realtime, Edge Functions and Studio — on your own server.

## 🚀 Installation

```bash
./local/deploy.sh supabase --ssh=vps --domain=supabase.example.com
```

**Requirements:**
- ⚠️ **Minimum 2GB RAM, recommended 3GB+**
- Supabase runs ~10 Docker containers (~3-4GB of images)
- Minimum 3GB of free disk space

## 💡 What is Supabase?

Supabase is a complete backend-as-a-service platform:

| Service | Description |
|---------|-------------|
| **PostgreSQL** | Database with Row Level Security |
| **Auth** | Magic links, OAuth, JWT tokens |
| **PostgREST** | Auto-generated REST API from your DB |
| **Realtime** | WebSocket subscriptions for DB changes |
| **Storage** | File storage (S3-compatible) |
| **Edge Functions** | Serverless functions (Deno) |
| **Studio** | Admin dashboard |

## 📌 After Installation

1. Open Studio: `http://localhost:8000` (or your domain)
2. Log in: `supabase` / `<password from install output>`
3. Configure SMTP in `/opt/stacks/supabase/.env`
4. Restart: `cd /opt/stacks/supabase && sudo docker compose restart`

## ⚙️ Installation Options

```bash
# With a custom domain (recommended for production)
./local/deploy.sh supabase --ssh=vps --domain=db.example.com

# Local only (access via SSH tunnel)
./local/deploy.sh supabase --ssh=vps --domain-type=local --yes
```

## 🔌 Using in Applications

```javascript
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  'https://db.example.com',   // SUPABASE_URL
  'eyJ...'                     // ANON_KEY (from install output)
)
```

## 📧 SMTP Configuration (required for production)

Edit `/opt/stacks/supabase/.env`:

```env
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=noreply@example.com
SMTP_PASS=your-smtp-password
SMTP_SENDER_NAME=YourApp
ENABLE_EMAIL_AUTOCONFIRM=false
```

Then: `cd /opt/stacks/supabase && sudo docker compose restart auth`

## 🔧 Management

```bash
cd /opt/stacks/supabase

sudo docker compose ps              # container status
sudo docker compose logs -f         # all service logs
sudo docker compose logs -f db      # PostgreSQL logs
sudo docker compose logs -f auth    # Auth (GoTrue) logs
sudo docker compose restart         # restart all
sudo docker compose down            # stop
sudo docker compose up -d           # start again
```

## 💾 Data and Backups

PostgreSQL data is stored in the `supabase_db-config` Docker volume.

Configuration saved by the installer:
```
~/.config/stackpilot/supabase/deploy-config.env
```

## 📊 Approximate RAM Usage

| Container | RAM |
|-----------|-----|
| db (PostgreSQL) | ~256MB |
| kong (API gateway) | ~256MB |
| analytics (Logflare) | ~512MB |
| studio (Next.js) | ~512MB |
| auth, rest, realtime, storage, meta | ~50-128MB each |
| **Total** | **~1.8-2.5GB** |
