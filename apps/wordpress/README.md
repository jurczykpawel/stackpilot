# WordPress - Performance Edition

The world's most popular CMS, optimized for small VPS servers.

**TTFB ~200ms** with cache (vs 2-5s on typical hosting). Zero configuration -- everything is automatic.

## What Is Inside?

Performance stack -- what you get at Kinsta ($35/mo) or WP Engine ($25/mo):

```
Caddy (host) -> Nginx (gzip, FastCGI cache, rate limiting, security)
                 +-- PHP-FPM alpine (OPcache + JIT, redis ext, WP-CLI)
                 +-- Redis (object cache, bundled)
                      +-- MySQL (external) or SQLite
```

### Optimizations (automatic, zero configuration)

| Optimization | What it does | On managed hosting |
|---|---|---|
| Nginx FastCGI cache + auto-purge | Cached pages ~200ms TTFB (no PHP or DB) | included in $25-35/mo plan |
| Redis Object Cache (drop-in) | -70% DB queries | Kinsta: addon $100/mo (!) |
| PHP-FPM alpine (not Apache) | -35MB RAM, smaller image | standard |
| OPcache + JIT | 2-3x faster PHP | standard |
| Nginx Helper plugin (auto-purge) | Cache cleared on content edit | built into Kinsta/WP Engine |
| WooCommerce-aware cache rules | Cart/checkout skip cache, rest cached | WP Rocket ~$59/yr |
| session.cache_limiter bypass | Cache works with Breakdance/Elementor (session_start fix) | manual configuration |
| fastcgi_ignore_headers | Nginx caches despite Set-Cookie from page builders | manual configuration |
| FastCGI cache lock | Thundering herd protection (1 req to PHP) | Nginx -- free, but requires know-how |
| Gzip compression | -60-80% transfer | standard |
| Open file cache | -80% disk I/O on static files | standard |
| Realpath cache 4MB | -30% response time (fewer stat() calls) | manual configuration |
| FPM ondemand + RAM tuning | Dynamic profile based on server RAM | managed hosting |
| tmpfs /tmp | 20x faster I/O for temp files | manual configuration |
| Security headers | X-Frame, X-Content-Type, Referrer-Policy | standard |
| Rate limiting wp-login | Brute force protection without loading PHP | plugin or manual |
| xmlrpc.php blocked | Closed DDoS vector | plugin or manual |
| User enumeration blocked | ?author=N -> 403 | plugin or manual |
| WP-Cron -> system cron | No delays for visitors | manual configuration |
| Autosave every 5 min | -80% DB writes (default is 60s) | manual configuration |
| Sensitive file blocking | wp-config.php, .env, uploads/*.php | plugin or manual |
| no-new-privileges | Container cannot escalate privileges | Docker know-how |
| Log rotation | Logs do not fill up disk (max 30MB) | standard |
| Converter for Media (WebP) | Auto-convert images to WebP (-25-35% vs JPEG) | plugin + manual config |

### Benchmark: TTFB

| Metric | Shared hosting | VPS WP |
|---|---|---|
| TTFB (homepage) | 800-3000ms | **~200ms** (cache HIT) |
| TTFB (cold, no cache) | 2000-5000ms | **300-400ms** |
| TTFB with Breakdance/Elementor | 2000-5000ms (session kills cache) | **~200ms** (session bypass) |

## Installation

### MySQL Mode (default)

```bash
# Bundled MySQL (free)
./local/deploy.sh wordpress --ssh=ALIAS --domain-type=caddy --domain=auto

# Custom MySQL
./local/deploy.sh wordpress --ssh=ALIAS --db-source=custom --domain-type=caddy --domain=auto
```

### SQLite Mode (lightweight, no MySQL)

```bash
WP_DB_MODE=sqlite ./local/deploy.sh wordpress --ssh=ALIAS --domain-type=caddy --domain=auto
```

### Redis (external vs bundled)

By default, auto-detection: if port 6379 is listening on the server, WordPress connects to the existing Redis (no new container). Otherwise it bundles `redis:alpine`.

```bash
# Force bundled Redis (even when external exists)
WP_REDIS=bundled ./local/deploy.sh wordpress --ssh=ALIAS

# Force external Redis (host)
WP_REDIS=external ./local/deploy.sh wordpress --ssh=ALIAS

# External Redis with password
REDIS_PASS=secretPassword WP_REDIS=external ./local/deploy.sh wordpress --ssh=ALIAS

# Auto-detection (default)
./local/deploy.sh wordpress --ssh=ALIAS
```

## Multiple WordPress Sites on One Server

Each deploy with a separate domain creates an independent instance:

```bash
./local/deploy.sh wordpress --domain=blog.example.com    # -> /opt/stacks/wordpress-blog/
./local/deploy.sh wordpress --domain=shop.example.com    # -> /opt/stacks/wordpress-shop/
./local/deploy.sh wordpress --domain=news.example.com    # -> /opt/stacks/wordpress-news/
```

What is shared vs separate:

| Element | Shared? |
|---|---|
| Redis | yes -- one `redis-shared` on `127.0.0.1:6379` (installed automatically) |
| Nginx | no -- separate per instance |
| PHP-FPM | no -- separate per instance |
| WP files | no -- separate volume per instance |
| Redis keys | isolated by prefix (`wordpress-blog:`, `wordpress-shop:`) |

Each additional site costs ~80MB RAM (PHP-FPM + Nginx). Shared Redis saves ~96MB vs separate per site.

## Requirements

- **RAM:** ~80-100MB idle (WP + Nginx + Redis), works on a 1GB RAM VPS
- **Disk:** ~550MB (Docker images: WP+redis ext, Nginx, Redis)
- **MySQL:** Bundled or custom. SQLite mode does not require MySQL.

## After Installation

1. Open the page -> WordPress installation wizard (the only manual step)

Optimizations from `wp-init.sh` run **automatically** after the wizard. No manual steps required.

`wp-init.sh` automatically:
- Generates `wp-config-performance.php` (HTTPS fix, limits, Redis config)
- Installs, activates and **configures** the **Redis Object Cache** plugin -- enables drop-in (`wp redis enable`), ready immediately
- Installs, activates and **configures** the **Nginx Helper** plugin -- sets file-based purge, auto-purge on edit/delete/comment
- Installs and activates the **Converter for Media** plugin -- new images converted to WebP automatically, nginx serves WebP without extra configuration
- Adds system cron every 5 min (replaces wp-cron)
- Clears FastCGI cache after configuration

**All plugins work out of the box -- zero configuration in the WordPress panel.**

If WordPress is not yet initialized, wp-init.sh sets a retry cron (every minute, max 30 attempts) and will finish configuration automatically.

## FastCGI Cache

Pages are cached by Nginx for 24h. **TTFB ~200ms** with cache vs 300-3000ms without.

### Automatic purge (Nginx Helper)

The Nginx Helper plugin automatically clears cache when:
- You edit/publish a page or post
- You delete a page or post
- Someone adds/removes a comment
- You update menus or widgets

Mode: **file-based purge** (unlink_files) -- fastest, no HTTP requests.

### Skip cache rules

Cache is automatically skipped for:
- Logged-in users (cookie `wordpress_logged_in`)
- Admin panel (`/wp-admin/`)
- API (`/wp-json/`)
- POST requests
- **WooCommerce:** cart, checkout, my-account (cookie `woocommerce_cart_hash`)

### Page builder compatibility

Breakdance, Elementor and other page builders call `session_start()`, which by default sends `Cache-Control: no-store` and blocks caching. Our solution:
- `session.cache_limiter =` -- PHP does not send Cache-Control header
- `fastcgi_ignore_headers Cache-Control Expires Set-Cookie` -- Nginx caches despite Set-Cookie

**Result:** pages with Breakdance cached normally (~200ms vs 2-5s on other hosting).

### Thundering herd protection

When many users request the same uncached page, only 1 request hits PHP-FPM, the rest wait for cache. `fastcgi_cache_background_update` serves stale content during refresh.

### Manual cache clearing

```bash
ssh ALIAS 'cd /opt/stacks/wordpress && ./flush-cache.sh'
```

The `X-FastCGI-Cache` header in HTTP responses shows status: `HIT`, `MISS`, `BYPASS`.

### Why Nginx, not LiteSpeed?

Many hosting providers advertise "LiteSpeed Cache". It sounds like an advantage, but independent benchmarks show otherwise:

**With caching enabled, both technologies give practically identical TTFB.** Both serve pages from server-level cache, without touching PHP or the database.

Independent tests (not hosting marketing):

| Test | Nginx | OpenLiteSpeed | Difference | Source |
|---|---|---|---|---|
| Cached TTFB | 67ms | 68ms | **1ms** | [WPJohnny](https://wpjohnny.com/nginx-vs-openlitespeed-speed-comparison/) |
| Throughput (cached) | 26,880 hits | 26,748 hits | **0.5%** | [RunCloud](https://runcloud.io/blog/openlitespeed-vs-nginx-vs-apache) |
| Uncached req/sec | **40 req/s** | 23 req/s | **Nginx 1.75x faster** | [WPJohnny](https://wpjohnny.com/litespeed-vs-nginx/) |

Quote from WPJohnny (independent WP consultant): *"OpenLiteSpeed and NGINX are just about equal in performance with caching on. Anybody claiming one is incredibly superior than the other is either biased or hasn't tested them side-by-side."*

Furthermore -- **on pages without cache (MISS), Nginx + PHP-FPM is faster** than OpenLiteSpeed.

| | Nginx FastCGI cache (ours) | LiteSpeed LSCache |
|---|---|---|
| TTFB (cache HIT) | ~200ms | ~200ms |
| TTFB (cache MISS) | **faster** (PHP-FPM) | slower |
| Auto-purge | Nginx Helper (plugin) | LSCache (plugin) |
| Redis Object Cache | yes (bundled) | yes (if hosting provides it) |
| Gzip | yes (-82% transfer) | yes |
| WooCommerce rules | auto (skip_cache) | manual plugin config |
| Breakdance/Elementor fix | auto (session.cache_limiter) | manual config |

Hosting providers boast LiteSpeed because they have it in their infrastructure. We have Nginx with FastCGI cache -- **same TTFB on cached, faster on uncached**. "LiteSpeed" is a server name, not a magic speed boost.

## Additional Optimization (manual)

### Cloudflare Edge Cache

When deploying with `--domain-type=cloudflare`, zone and cache rule optimization runs **automatically**.

Manual run (e.g. after domain change):
```bash
./local/setup-cloudflare-optimize.sh wp.your-domain.com --app=wordpress
```

What it sets:
- **Zone:** SSL Flexible, Brotli, Always HTTPS, HTTP/2+3, Early Hints
- **Bypass cache:** `/wp-admin/*`, `/wp-login.php`, `/wp-json/*`, `/wp-cron.php`
- **Cache 1 year:** `/wp-content/uploads/*` (media), `/wp-includes/*` (core static)
- **Cache 1 week:** `/wp-content/themes/*`, `/wp-content/plugins/*` (assets)

Cloudflare edge cache works **on top of** Nginx FastCGI cache - statics served from CDN without touching the server. For HTML pages, FastCGI cache is better (knows logged-in user context).

### Converter for Media (WebP)

The **Converter for Media** plugin is installed and activated automatically. New images uploaded to the Media Library are converted to WebP right away.

To convert existing images, use bulk conversion in the WP panel (Media -> Converter for Media -> Start Bulk Optimization) or WP-CLI:

```bash
ssh ALIAS 'docker exec $(docker compose -f /opt/stacks/wordpress/docker-compose.yaml ps -q wordpress) wp converter-for-media regenerate --path=/var/www/html'
```

## Security

| Protection | Description |
|---|---|
| Rate limiting wp-login.php | 1 req/s with burst 3 (429 Too Many Requests) |
| xmlrpc.php blocked | deny all (DDoS and brute force vector) |
| User enumeration blocked | ?author=N -> 403 |
| File editing from WP panel | Blocked (DISALLOW_FILE_EDIT) |
| PHP in uploads/ | Blocked (deny all) |
| no-new-privileges | Container cannot escalate privileges |
| Security headers | X-Frame, X-Content-Type, Referrer-Policy, Permissions-Policy |

## Backup

```bash
./local/setup-backup.sh ALIAS
```

Data in `/opt/stacks/wordpress/`:
- `wp-content/` - plugins, themes, uploads, SQLite database
- `config/` - PHP/Nginx/FPM configuration
- `redis-data/` - Redis cache
- `docker-compose.yaml`

## RAM Profiling

The script automatically detects RAM and adjusts PHP-FPM:

| Server RAM | FPM workers | WP limit | Nginx limit |
|---|---|---|---|
| 512MB | 4 | 192M | 32M |
| 1GB | 8 | 256M | 48M |
| 2GB+ | 15 | 256M | 64M |

Redis: 64MB maxmemory (allkeys-lru) + 96MB Docker limit for all profiles.
