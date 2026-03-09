# Uptime Kuma - Your Night Watchman

Beautiful and simple monitoring dashboard. Replaces the paid UptimeRobot.

## Installation

```bash
./local/deploy.sh uptime-kuma --ssh=ALIAS --domain-type=cloudflare --domain=status.example.com
# or locally (SSH tunnel):
./local/deploy.sh uptime-kuma --ssh=ALIAS --domain-type=local --yes
```

## Requirements

- **RAM:** ~256MB (container limit: 256MB)
- **Disk:** ~500MB (Docker image)
- **Port:** 3001

## After Installation

1. Open the URL in your browser.
2. On first visit, Uptime Kuma will ask you to create an administrator account. Save the credentials in a secure place.
3. Add your first monitor: click "+ Add New Monitor", choose type (HTTP, TCP, etc.), enter your URL.

## Business Use Case

Your n8n automations must run 24/7. But how do you know if they are running?
1. Configure Uptime Kuma to check your n8n webhooks or Sellf page every minute.
2. Connect notifications (e.g. to **ntfy** or Telegram).
3. Sleep peacefully. If something goes down, your phone will wake you up.
