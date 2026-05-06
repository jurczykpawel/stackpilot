# Frog (Mikrus Free Tier) Setup

This guide covers the one-time setup needed before you can use StackPilot scripts on a [Mikrus "frog"](https://wiki.mikr.us/frog/) server (the free tier).

## Why frog needs a different setup

Frog servers are Alpine Linux LXC containers with:

- **Own global IPv6** address
- **Shared IPv4** with only 3 high TCP/UDP ports exposed (`*0925`, `*1925`, etc.)
- **No public port 80/443** — Mikrus's edge firewall blocks inbound traffic on these ports for free-tier instances. Even Cloudflare's IP ranges are not whitelisted (unlike paid Mikrus plans).

The standard flow (`AAAA + Cloudflare proxy + Caddy on port 80`) returns HTTP 521 from Cloudflare because the proxy cannot reach the origin. Instead, frog uses a **Cloudflare Tunnel**: a daemon on the server (`cloudflared`) dials outbound to Cloudflare's network on port 7844 (explicitly allowed by Mikrus). All inbound traffic for your domain travels through that tunnel — no inbound firewall rules needed.

## One-time setup (~5 minutes)

### 1. Install `cloudflared` binary on frog

The official Cloudflare binary, statically linked, no dependencies. Alpine's stable repos do not ship `cloudflared` — only `edge/testing` does, so the binary download is the cleanest path.

```bash
ssh frog
sudo wget -O /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
sudo chmod +x /usr/local/bin/cloudflared
cloudflared --version    # sanity check
```

### 2. Create the tunnel in Cloudflare Dashboard

1. Open <https://one.dash.cloudflare.com/> → **Networks → Tunnels → Create a tunnel**.
2. Connector type: **Cloudflared**. Name it however you want (e.g. `frog`).
3. Click **Save tunnel**.
4. On the next page ("Install and run a connector"), choose **Linux** as the environment. Cloudflare shows an install command like:
    ```
    sudo cloudflared service install eyJhIj...long-token...
    ```
    Copy the whole command. The simplest path on Alpine is to **run it as-is** — `cloudflared` detects that the system uses SysV-style init scripts (which OpenRC also manages on Alpine) and writes `/etc/init.d/cloudflared` itself.

### 3. Run the install + force HTTP/2 protocol

```bash
# Run the command Dashboard gave you (with your real token):
sudo cloudflared service install eyJhIj...your-token...

# CRITICAL: Force HTTP/2 (TCP) instead of QUIC (UDP).
# QUIC is unreliable on frog's LXC + NAT setup and causes the tunnel to
# disconnect every minute or two. HTTP/2 is the documented fallback and
# is rock-solid here. Skipping this step makes the tunnel flap.
sudo sed -i 's|tunnel run --token|tunnel run --protocol http2 --token|' /etc/init.d/cloudflared
sudo rc-service cloudflared restart
```

### 4. Verify

```bash
sleep 5 && sudo tail -20 /var/log/cloudflared.err
```

In the logs you should see four lines like `Registered tunnel connection ... protocol=http2`. In the Cloudflare Dashboard the tunnel flips from **Down/Inactive** to **Healthy**.

That's it. The tunnel runs as a daemon and reconnects on its own.

## Per-domain setup (Cloudflare Dashboard)

For each domain you want to serve from frog:

1. Cloudflare Dashboard → **Networks → Tunnels → \<your tunnel\> → Public Hostnames → Add a public hostname**.
2. Fill in:
    - **Subdomain**: e.g. `app`
    - **Domain**: e.g. `example.com`
    - **Service Type**: `HTTP`
    - **URL**: `localhost:80`
3. Save.

Cloudflare automatically creates a CNAME `app.example.com → <tunnel-uuid>.cfargotunnel.com` with proxy on. SSL is managed by Cloudflare (Universal SSL — covers any subdomain on a zone you own).

The traffic path is now:

```
Client (HTTPS)
  ↓
Cloudflare edge (TLS termination, free Universal SSL cert)
  ↓
cloudflared on frog (via outbound port 7844)
  ↓
localhost:80 on frog
  ↓
Caddy (matches by Host header → conf.d/<domain>.caddy → file_server)
```

## Deploying with StackPilot

Once cloudflared is running and you've added the public hostname, deploying is the same as any other server:

```bash
./local/add-static-hosting.sh app.example.com frog ./dist
```

The script auto-detects frog (Alpine + no `/klucz_api`), verifies cloudflared is running, **skips DNS** (managed by CF Tunnel), and configures Caddy locally. If cloudflared is not running it bails out with a pointer back here.

## Performance characteristics

Measured on a frog VPS in Helsinki serving a static `index.html` (669 B) through the cloudflared tunnel + Caddy + Cloudflare Universal SSL, tested from a Polish residential connection. Cold connection establishment is excluded — these are warm-cache numbers (after the first request has primed TLS, tunnel routing, and CF edge).

### Latency (single user, sequential)

| | p50 | p95 | p99 |
| :--- | :--- | :--- | :--- |
| 50 sequential requests | 70 ms | 110 ms | 137 ms |

### Throughput (concurrent users)

| Concurrency | Throughput | p50 | p95 | p99 |
| :--- | :--- | :--- | :--- | :--- |
| 5 | 55 req/s | 79 ms | 158 ms | 194 ms |
| 10 | 105 req/s | 84 ms | 116 ms | 136 ms |
| 20 | **224 req/s** | 75 ms | 143 ms | 144 ms |

These numbers were measured with **no other heavy services on the frog VPS** (Docker daemon idle). The cloudflared tunnel itself is not the bottleneck — at c=20 throughput is comparable to a paid Mikrus serving over CF Flexible directly.

### What hurts performance on frog

A frog VPS has only **256 MB RAM and 1 vCPU**. Co-locating other Docker workloads (especially anything Node.js / JVM) eats into available RAM and degrades the static-hosting tail badly:

| Scenario | c=5 throughput | c=5 p99 |
| :--- | :--- | :--- |
| Static hosting only | **55 req/s** | **194 ms** |
| Static hosting + ntfy + uptime-kuma running | 8.7 req/s | 3 031 ms |

When RAM is tight, the kernel page-thrashes under load and the cloudflared/Caddy processes can't service connections quickly enough. Throughput collapses, p99 spikes to seconds.

Concurrency above ~20 may also hit Cloudflare's per-IP rate limits — that's a CF-side throttle, not a server problem (back off for ~90 s and it clears).

### Recommendations for serious static hosting on frog

1. **Make frog a dedicated static host** — move ntfy / uptime-kuma / other services to a different server. Frog's 256 MB is enough for cloudflared + Caddy + serving files, not much more.
2. **Use Cloudflare cache rules** — set `Cache-Control: public, max-age=31536000, immutable` on hashed assets and configure CF Cache Rules to "Cache Everything" for static paths. With aggressive edge caching, ~99% of requests never touch the origin, and the 256 MB RAM ceiling stops mattering.
3. **Avoid hosting anything dynamic** — frog is fine for HTML/CSS/JS/images. Anything that fans out to a database or upstream API will starve under the same RAM constraints.

For dynamic apps or high-traffic sites, consider a paid Mikrus (more RAM + Cloudflare-IP whitelist for direct AAAA + CF Flexible) or a different VPS provider.

## Troubleshooting

**`cloudflared --version` fails / wget downloaded an HTML page** — GitHub redirects might fail on stale TLS roots. Try `wget --no-check-certificate` (only as a last resort) or download manually and `scp` the binary up.

**Tunnel reconnects every 1-2 minutes** (logs full of `Connection terminated`, `connection with edge closed`, `timeout: no recent network activity`) — you skipped the `--protocol http2` step. QUIC over UDP is unreliable on frog. Re-run the `sed` line from step 3 and restart cloudflared.

**Tunnel stays "Down" in Dashboard** — token typo or whitespace. Run `sudo cloudflared service uninstall` and reinstall with the install command exactly as shown by the Dashboard.

**Domain returns "Error 1033 — Argo Tunnel error"** — tunnel is up but the Host header has no matching Public Hostname, or the service URL points to a port nothing listens on. Check the Tunnel dashboard's Public Hostnames tab. Also occurs briefly during a tunnel reload — wait 10 s and retry.

**Domain returns redirect loop (HTTP 308 to itself)** — Caddy was configured with a bare `domain { ... }` block instead of `http://domain { ... }`. The bare form auto-redirects HTTP→HTTPS, but the tunnel always sends HTTP, so it loops. `add-static-hosting.sh` handles this automatically when it detects frog. If you're configuring `sp-expose` manually, pass `--cloudflare`.

**Domain returns 502 from Caddy** — cloudflared reaches frog, Caddy is up, but the path/file isn't where Caddy expects. `ssh frog 'sudo ls /var/www/<domain>/'` and `sudo cat /etc/caddy/conf.d/<domain>.caddy`.

**Update cloudflared**: `sudo wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && sudo chmod +x /usr/local/bin/cloudflared && sudo rc-service cloudflared restart`. Token and init script stay intact.

## Removal

```bash
sudo cloudflared service uninstall
sudo rm /usr/local/bin/cloudflared
```

Then delete the tunnel in Cloudflare Dashboard. The CNAME records you added auto-clean when you remove Public Hostnames.
