# Uptime Kuma - Your Night Watchman

Beautiful and simple monitoring dashboard. Replaces the paid UptimeRobot.

## Installation

```bash
./local/deploy.sh uptime-kuma
```

## Business Use Case
Your n8n automations must run 24/7. But how do you know if they are running?
1. Configure Uptime Kuma to check your n8n webhooks or GateFlow page every minute.
2. Connect notifications (e.g. to **ntfy** or Telegram).
3. Sleep peacefully. If something goes down, your phone will wake you up.

## After Installation - Domain Configuration

### 1. Configure DNS
Add an A record in your domain registrar panel (e.g. OVH, Cloudflare):
- **Type:** `A`
- **Name:** `status` (or another subdomain, e.g. `uptime`, `monitor`)
- **Value:** Your server's IP address
- **TTL:** 3600 (or "Auto")

> DNS propagation may take from a few minutes to 24h. Check: `ping status.your-domain.com`

### 2. Expose the App via HTTPS
Run **on your local machine** (not on the server!):
```bash
ssh ALIAS 'sp-expose status.your-domain.com 3001'
```
Replace `ALIAS` with your SSH alias and `status.your-domain.com` with your domain.

### 3. Create an Admin Account
On first visit to `https://status.your-domain.com`, Uptime Kuma will ask you to create an administrator account. Save the login credentials in a secure place!
