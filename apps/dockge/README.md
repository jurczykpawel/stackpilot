# Dockge - Container Management Panel

Dockge is an ultra-lightweight interface for managing Docker Compose. Replaces the heavy Portainer.

## Installation

```bash
./local/deploy.sh dockge
```

## Why Dockge?
- **Low RAM usage:** Unlike Portainer, which can consume 200MB+, Dockge uses very little.
- **Files > Database:** Dockge does not hide your configurations in an internal database. It manages `compose.yaml` files directly in the `/opt/stacks` directory. This means you can edit them in the browser, through the terminal, or in VS Code, and nothing gets out of sync.
- **Agent:** You can connect other servers to a single panel.

## After Installation - Domain Configuration

### 1. Configure DNS
Add an A record in your domain registrar panel (e.g. OVH, Cloudflare):
- **Type:** `A`
- **Name:** `dockge` (or another subdomain, e.g. `docker`, `panel`)
- **Value:** Your server's IP address
- **TTL:** 3600 (or "Auto")

> DNS propagation may take from a few minutes to 24h. Check: `ping dockge.your-domain.com`

### 2. Expose the App via HTTPS
Run **on your local machine** (not on the server!):
```bash
ssh ALIAS 'sp-expose dockge.your-domain.com 5001'
```
Replace `ALIAS` with your SSH alias and `dockge.your-domain.com` with your domain.

### 3. Create an Admin Account
On first visit to `https://dockge.your-domain.com`, Dockge will ask you to create an administrator account. Save the login credentials in a secure place!

## How to Use?
After domain configuration, go to `https://dockge.your-domain.com`.
Click "+ Compose", enter a name (e.g. `wordpress`) and paste the configuration. That is all.
