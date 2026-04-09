# Countdown Timer

Self-hosted animated countdown timer GIF generator for emails, landing pages, and anywhere images work.

**RAM:** ~0MB extra (uses existing PHP-FPM) | **Disk:** ~2MB | **Port:** via Caddy (no dedicated port) | **Database:** No | **Docker:** No

## Quick Start

```bash
./local/deploy.sh countdown-timer --ssh=vps --domain-type=cloudflare --domain=timer.example.com
```

## What Gets Installed

- PHP files cloned from [GitHub](https://github.com/jurczykpawel/countdown-timer)
- PHP-FPM + php-gd (auto-installed if missing)
- Caddy configured with php_fastcgi
- Cache directories at `/var/cache/timer-gif/`
- Cron job for automatic cache cleanup
- Random master API key generated

## Requirements

- **PHP 8.1+** with GD extension (auto-installed)
- **Caddy** (auto-installed by StackPilot)

## After Installation

1. **Save your API key** - shown once during install (`tk_master_...`)
2. **Test:** `https://your-domain/?preset=dark-boxes&evergreen=2h&key=YOUR_KEY`
3. **Landing page:** `https://your-domain/` (no key needed)

## Features

- 5 visual presets (dark-boxes, gradient-cards, minimal-light, bold-color, transparent)
- Digit boxes (rounded, gradient, outline), separators, 3 fonts
- Absolute timers (`?time=2026-12-25T00:00:00`) and evergreen (`?evergreen=2h`)
- UID-based persistent evergreen (deadline saved per unique user)
- API key auth with per-key daily quotas
- Multi-layer caching (PHP filesystem + CDN headers)
- Rate limiting (30 req/min per IP)

## Files

```
/var/www/countdown-timer/     # Application
/var/cache/timer-gif/         # GIF cache (auto-cleaned by cron)
/etc/cron.d/timer-gif-cache   # Cache cleanup cron
```

## Management

```bash
# Update to latest version
ssh vps 'cd /var/www/countdown-timer && git pull'

# Edit API keys
ssh vps 'nano /var/www/countdown-timer/keys.json'

# View PHP-FPM errors
ssh vps 'tail -f /var/log/php*-fpm.log'

# Clear GIF cache
ssh vps 'rm -rf /var/cache/timer-gif/ab/* /var/cache/timer-gif/ev/*'
```
