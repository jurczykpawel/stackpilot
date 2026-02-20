# ntfy - Your Notification Center

A server for sending PUSH notifications to phone and desktop. Replaces paid Pushover.

## Installation

```bash
./local/deploy.sh ntfy
```

## How Does It Work?
1. Install the ntfy app on your phone (Android/iOS).
2. Subscribe to your topic, e.g. `my-secret-topic`.
3. In n8n, use an HTTP Request node to send a POST to your ntfy server.
4. **Done!** You get a notification on your phone: "New order in GateFlow: $97".

## After Installation - Domain Configuration

### 1. Configure DNS
Add an A record in your domain registrar panel (e.g. OVH, Cloudflare):
- **Type:** `A`
- **Name:** `notify` (or another subdomain, e.g. `ntfy`, `push`)
- **Value:** Your server's IP address
- **TTL:** 3600 (or "Auto")

> DNS propagation may take from a few minutes to 24h. Check: `ping notify.your-domain.com`

### 2. Expose the App via HTTPS
Run **on your local machine** (not on the server!):
```bash
ssh ALIAS 'sp-expose notify.your-domain.com 8085'
```
Replace `ALIAS` with your SSH alias and `notify.your-domain.com` with your domain.

### 3. Update NTFY_BASE_URL
ntfy needs to know its public domain. Run **locally**:
```bash
ssh ALIAS "sed -i 's|notify.example.com|notify.your-domain.com|' /opt/stacks/ntfy/docker-compose.yaml && cd /opt/stacks/ntfy && docker compose up -d"
```

### 4. Create an Admin User
ntfy has its own user system (unrelated to the Linux system). Run **locally**:
```bash
ssh ALIAS 'docker exec -it ntfy-ntfy-1 ntfy user add --role=admin myuser'
```
The command will ask for a password. This user is for logging into the ntfy web interface.

## Security
The script sets "deny-all" mode by default (nobody can read/write without a password). This is why step 4 (creating a user) is mandatory.
