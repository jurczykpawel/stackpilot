# KSeF Gateway

Universal REST API gateway for Poland's National e-Invoice System (KSeF).

- **Source:** https://github.com/jurczykpawel/ksef-gateway
- **API Docs:** `http://HOST:PORT/scalar/v1`

## Requirements

| Resource | Value |
|----------|-------|
| RAM | ~576 MB (384M API + 192M PDF) |
| Disk | ~600 MB (Docker images) |
| Port | 8080 (default) |
| Database | None |

## Installation

### 1. Generate KSeF test token

On your local machine (requires Docker):

```bash
git clone --recurse-submodules https://github.com/jurczykpawel/ksef-gateway.git
cd ksef-gateway
cp .env.example .env
# Set GITHUB_PAT in .env (https://github.com/settings/tokens/new?scopes=read:packages)
docker compose --profile tools run --rm token-generator
```

Copy the output: `KSEF_TOKEN`, `KSEF_NIP`.

### 2. Deploy

```bash
# Basic (local access via SSH tunnel)
KSEF_TOKEN=<token> KSEF_NIP=<nip> ./local/deploy.sh ksef-gateway --ssh=vps --domain-type=local --yes

# With domain
KSEF_TOKEN=<token> KSEF_NIP=<nip> ./local/deploy.sh ksef-gateway --ssh=vps --domain-type=cloudflare --domain=ksef.example.com

# Production environment
KSEF_TOKEN=<token> KSEF_NIP=<nip> KSEF_ENV=PRODUCTION ./local/deploy.sh ksef-gateway --ssh=vps --domain-type=cloudflare --domain=ksef.example.com
```

### 3. Verify

```bash
# Health check
curl http://localhost:8080/health

# API docs
open http://localhost:8080/scalar/v1
```

## Access via SSH Tunnel

If deployed with `--domain-type=local`:

```bash
ssh -L 8080:localhost:8080 vps
# Then open http://localhost:8080/scalar/v1
```

## Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/ksef/invoice` | Send invoice (friendly JSON) |
| POST | `/ksef/send` | Send invoice (FA(3) XML) |
| GET | `/ksef/invoice/{nr}` | Download invoice XML |
| GET | `/ksef/invoice/{nr}/pdf` | Download invoice PDF with QR |
| GET | `/ksef/status` | Gateway + KSeF status |
| GET | `/health` | Health check |

Full API docs at `/scalar/v1` (60+ endpoints).

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| KSEF_TOKEN | Yes | - | KSeF authentication token |
| KSEF_NIP | Yes | - | NIP for authentication context |
| KSEF_ENV | No | TEST | TEST, DEMO, or PRODUCTION |
| PORT | No | 8080 | API port |
