# Server-Side Google Tag Manager (sGTM)

Self-hosted GTM server container. Runs Google Tag Manager on your own server instead of Google's infrastructure, enabling 1st-party data collection and bypassing ad blockers.

## Installation

```bash
# Get CONTAINER_CONFIG from: GTM UI → Admin → Container Settings → Container Config
CONTAINER_CONFIG="ZW52LCJodHRwczovL..." \
  ./local/deploy.sh sgtm \
  --ssh=vps \
  --domain-type=cloudflare \
  --domain=gtm.example.com
```

## Requirements

- **RAM:** ~256MB (container limit: 256MB)
- **Disk:** ~300MB (Docker image)
- **Port:** 8084
- **Domain:** Required — sGTM must be served over HTTPS on your custom subdomain
- **CONTAINER_CONFIG:** Base64-encoded config string from GTM UI

## Getting CONTAINER_CONFIG

1. Open Google Tag Manager → select your **server** container
2. Go to **Admin** → **Container Settings**
3. Copy the value from **Container Config** field
4. Pass it as the `CONTAINER_CONFIG` env variable when deploying

## After Installation

1. **Set server container URL in GTM:**
   - GTM → Admin → Container Settings → Server Container URL
   - Enter: `https://your-gtm-domain.example.com`

2. **Update client-side GA4 tag:**
   - In your web container, edit the GA4 Configuration tag
   - Set `server_container_url` to your sGTM domain

3. **Test:** Use GTM preview mode to verify events flow through sGTM

## Health Check

sGTM exposes a health endpoint at `/healthz` (returns HTTP 200 when ready).

## Business Use Case

- Bypass ad blockers (1st-party domain)
- Server-side event enrichment before sending to GA4 / Meta CAPI / Google Ads
- Reduce client-side JavaScript load
- GDPR: process and filter data before it reaches third parties
