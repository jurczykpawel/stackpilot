# Domain Setup with Cloudflare

This guide shows how to set up your domain with Cloudflare so you can use DNS automation in StackPilot.

## Why Cloudflare?

1. **IPv4/IPv6 translation** - If your VPS only has an IPv6 address, Cloudflare acts as a proxy so IPv4-only clients can still reach it.
2. **DNS automation** - The `dns-add.sh` script automatically adds DNS records via the Cloudflare API.
3. **Free SSL** - Cloudflare provides SSL certificates with no configuration needed.
4. **DDoS protection** - Free basic protection against attacks.
5. **CDN** - Faster page loading for users worldwide.

## Step 1: Get a Domain

If you do not have a domain yet, purchase one from any domain registrar (Namecheap, Porkbun, Google Domains, GoDaddy, OVH, etc.).

Choose a registrar with fair renewal prices. Many registrars offer cheap first-year pricing but charge significantly more on renewal.

## Step 2: Create a Free Cloudflare Account

1. Go to [cloudflare.com](https://www.cloudflare.com/) and click "Sign Up"
2. Enter your email and password
3. Choose the **Free** plan

> The free plan is genuinely sufficient:
> - Unlimited number of domains
> - Full API for DNS automation
> - SSL/HTTPS for all domains
> - CDN and DDoS protection
> - No traffic limits
>
> Paid plans ($20+/month) are for large businesses with millions of visitors. For a VPS and small business, **Free = everything you need**.

## Step 3: Add Your Domain to Cloudflare

1. After logging in, click **"Add a Site"**
2. Enter your domain (e.g. `example.com`) - without `www`!
3. Choose the **Free** plan
4. Cloudflare will scan existing DNS records

## Step 4: Change Nameservers at Your Registrar

Cloudflare will show you two nameservers, for example:
```
aria.ns.cloudflare.com
brett.ns.cloudflare.com
```

Now set these at your domain registrar:

1. Log in to your registrar's control panel
2. Navigate to your domain's DNS settings
3. Change the nameservers to the ones Cloudflare provided
4. Save changes

> **Note:** Nameserver changes can take up to 24-48 hours to propagate, but usually work within 1-2 hours.

## Step 5: Confirm in Cloudflare

1. Go back to Cloudflare
2. Click **"Check nameservers"**
3. Once the nameservers propagate, you will see status **"Active"**

## Step 6: Configure SSL in Cloudflare

1. In Cloudflare, go to **SSL/TLS** -> **Overview**
2. Set the mode to **"Full"** (not "Flexible"!)

> **Important:** The "Flexible" mode can cause redirect loops with Caddy. Use "Full".

## Step 7: Configure Automation in StackPilot

Now you can set up automatic DNS record management:

```bash
cd stackpilot
./local/setup-cloudflare.sh
```

The script will:
1. Open your browser to the Cloudflare API token creation page
2. Create a token with "Edit zone DNS" permission
3. Paste the token in the terminal
4. Done!

## Usage

Adding a domain is now a single command:

```bash
# Add a DNS record (IPv6 is fetched automatically!)
./local/dns-add.sh status.example.com vps

# Expose an application via HTTPS
ssh vps 'sp-expose status.example.com 3001'
```

## Verification

Check whether the domain works:

```bash
# Check DNS
ping status.example.com

# Check HTTPS
curl -I https://status.example.com
```

## Troubleshooting

### "DNS not propagated yet"
Wait 5-10 minutes. Cloudflare is fast, but propagation can take a moment.

### "SSL certificate error"
1. Verify that Cloudflare SSL mode is set to "Full" (not "Flexible")
2. Check that the proxy is enabled (orange cloud icon next to the DNS record)

### "502 Bad Gateway"
1. Check that the application is running: `ssh vps 'docker ps'`
2. Check that the port is correct in `sp-expose`

### "Connection refused"
1. Make sure Caddy is installed: `ssh vps 'which caddy'`
2. Check Caddy status: `ssh vps 'systemctl status caddy'`

---

## Alternative: Cloudflare Registrar

You can also transfer your entire domain to Cloudflare Registrar - this keeps everything in one place and is often cheaper. The option is available under Cloudflare -> Domain Registration -> Transfer Domains.
