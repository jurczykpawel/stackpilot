# KSeF Gateway — self-hosted e-invoicing API for Poland

Universal REST API gateway for Poland's national e-invoicing system (**KSeF**), wrapping the official CIRFMF KSeF SDK. Send and receive invoices, and render invoice PDFs with a verification QR code — over a plain HTTP API. Open source, self-hosted, no per-invoice fees.

## Installation

```bash
./local/deploy.sh ksef-gateway --ssh=ALIAS --domain-type=cloudflare --domain=ksef.example.com
```

The installer generates the caller API key and the internal PDF-service secret itself, pulls the pre-built images from GHCR, and brings the stack up — no questions asked. It boots healthy immediately; you connect it to KSeF by adding your token afterwards.

### One-command install on a fresh VPS

```bash
curl -fsSL https://stackpilot.techskills.academy/ksef-gateway | bash
```

Runs directly on the server (installs the stack into `/opt/stacks/ksef-gateway`). Pair it with a domain via `deploy.sh` from your machine, or an SSH tunnel.

## Connecting to KSeF

The gateway is up but **unauthenticated** until you add a KSeF token:

1. Get a token for your NIP from the KSeF portal (TEST sandbox or PROD).
2. Add it to `/opt/stacks/ksef-gateway/.env`:
   ```
   KSEF_TOKEN=your-token
   KSEF_NIP=0000000000
   KSEF_ENV=TEST     # switch to PROD for real invoices
   ```
3. `cd /opt/stacks/ksef-gateway && sudo docker compose up -d`

You can also pass them at install time as env: `KSEF_TOKEN=… KSEF_NIP=… ./local/deploy.sh ksef-gateway …`.
Certificate-based auth is supported too — see the project README.

Verify:
```bash
curl https://ksef.example.com/ksef/status -H "X-Api-Key: <your key>"
```

## Requirements

- **RAM:** ~720MB cap (ksef-api 400M + ksef-pdf 320M; real idle ~110M + ~200M)
- **Disk:** ~900MB images, no data volume (stateless — no DB, no Redis)
- **Port:** 8080 (bound to `127.0.0.1` behind Caddy/Cloudflare)
- **Arch:** `linux/amd64` (the published images are amd64-only)
- **Network:** access to GHCR for the images

## Stack

| Component | Technology |
|-----------|------------|
| API | ASP.NET Core 9 Minimal API + CIRFMF KSeF SDK |
| PDF service | Node.js + pdfmake + CIRFMF ksef-pdf-generator (internal only) |
| Auth | `X-Api-Key` header on every request except `/health` |

Images: `ghcr.io/jurczykpawel/ksef-gateway-api` and `…-pdf`.

## Notes

- **`KSEF_ENV=TEST` by default** — a safe sandbox that does not issue real invoices. Switch to `PROD` only when you are ready to invoice for real.
- **Single NIP is always free.** Multiple NIPs (`contexts.json`) require a `GATEWAY_LICENSE`.
- Update to the latest image: `./local/deploy.sh ksef-gateway --update`.
