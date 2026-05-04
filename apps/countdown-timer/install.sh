#!/bin/bash

# StackPilot - Countdown Timer
# Self-hosted animated countdown timer GIF generator for emails and web.
# PHP-only app (no Docker). Uses PHP-FPM + Caddy.
# Author: Pawel (Lazy Engineer)
#
# NEEDS_DOCKER=false
# NEEDS_PHP=true
#
# Environment variables:
#   DOMAIN - domain for the timer service

set -e

# Domain is required for Caddy PHP hosting
if [ -z "$DOMAIN" ]; then
    echo "Error: DOMAIN is required. Use --domain=timer.example.com"
    exit 1
fi

APP_NAME="countdown-timer"
WEB_ROOT="/var/www/countdown-timer"
REPO_URL="https://github.com/jurczykpawel/countdown-timer.git"
CACHE_DIR="/var/cache/timer-gif"

echo "--- Countdown Timer Setup ---"
echo ""
echo "Installing:"
echo "  Countdown Timer GIF Generator (PHP application)"
echo ""

# ── 1. Install PHP-FPM + GD if missing ──────────────────────────────────────

PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || echo "")

if [ -z "$PHP_VER" ]; then
    echo "[1/5] Installing PHP-FPM..."
    apt-get update -qq && apt-get install -y -qq php-fpm php-gd 2>&1
    PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)
    PHP_SVC=$(systemctl list-unit-files | grep 'php.*fpm' | awk '{print $1}' | head -1)
    [ -n "$PHP_SVC" ] && systemctl enable "$PHP_SVC" && systemctl start "$PHP_SVC"
else
    echo "[1/5] PHP $PHP_VER found"
    # Ensure GD is installed
    if ! php -m 2>/dev/null | grep -qi gd; then
        echo "  Installing php-gd..."
        apt-get update -qq && apt-get install -y -qq "php${PHP_VER}-gd" 2>&1
        systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || true
    fi
fi

# ── 2. Clone repository ─────────────────────────────────────────────────────

echo "[2/5] Downloading countdown-timer..."
if [ -d "$WEB_ROOT/.git" ]; then
    cd "$WEB_ROOT" && git pull --ff-only 2>/dev/null || true
else
    rm -rf "$WEB_ROOT"
    git clone --depth 1 "$REPO_URL" "$WEB_ROOT"
fi

# ── 3. Configure API keys ───────────────────────────────────────────────────

echo "[3/5] Configuring API keys..."
if [ ! -f "$WEB_ROOT/keys.json" ]; then
    # Generate a random master key
    MASTER_KEY="tk_master_$(openssl rand -hex 16)"
    cat > "$WEB_ROOT/keys.json" << KEYSEOF
{
    "$MASTER_KEY": {
        "name": "Master",
        "limit": 0,
        "active": true
    }
}
KEYSEOF
    chmod 600 "$WEB_ROOT/keys.json"
    echo "  Master API key generated: $MASTER_KEY"
    echo "  (also stored in $WEB_ROOT/keys.json)"
else
    echo "  keys.json already exists, keeping it"
fi

# ── 4. Create cache directories ─────────────────────────────────────────────

echo "[4/5] Creating cache directories..."
mkdir -p "$CACHE_DIR"/{ab,ev,expired,uid,apikeys,ratelimit}
chown -R www-data:www-data "$CACHE_DIR"
chmod -R 755 "$CACHE_DIR"

# tmpfs for hot counter dirs — 3-5k file ops/s under load shouldn't hit disk.
# UID stays on disk (persistent deadlines). ab/ev cache stays on disk (size).
mount_tmpfs() {
    local target="$1" size="$2"
    if mountpoint -q "$target"; then
        return 0
    fi
    if ! grep -qE "^[^#]*[[:space:]]${target}[[:space:]]+tmpfs" /etc/fstab; then
        echo "tmpfs ${target} tmpfs rw,size=${size},mode=755,uid=$(id -u www-data),gid=$(id -g www-data) 0 0" \
            >> /etc/fstab
    fi
    mount "$target" || echo "  (mount failed for $target — will mount on next boot)"
}
mount_tmpfs "$CACHE_DIR/ratelimit" 64M
mount_tmpfs "$CACHE_DIR/apikeys" 64M

# Set web root permissions
chown -R www-data:www-data "$WEB_ROOT"

# ── 4b. PHP-FPM pool + OPcache tuning ───────────────────────────────────────

echo "[4b] Tuning PHP-FPM pool + OPcache..."
PHP_FPM_DIR="/etc/php/${PHP_VER}/fpm"
if [ -d "$PHP_FPM_DIR" ]; then
    # Size pool from RAM: 50% of RAM / 40MB per worker, clamped 4..64
    TOTAL_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024)
    MAX_CHILDREN=$(( TOTAL_MB / 2 / 40 ))
    [ "$MAX_CHILDREN" -lt 4 ] && MAX_CHILDREN=4
    [ "$MAX_CHILDREN" -gt 64 ] && MAX_CHILDREN=64
    START_SERVERS=$(( MAX_CHILDREN / 4 ))
    [ "$START_SERVERS" -lt 2 ] && START_SERVERS=2
    MIN_SPARE=$START_SERVERS
    MAX_SPARE=$(( MAX_CHILDREN / 2 ))
    [ "$MAX_SPARE" -lt 4 ] && MAX_SPARE=4

    cat > "$PHP_FPM_DIR/pool.d/countdown-timer.conf" << POOLEOF
; StackPilot countdown-timer pool overrides (sized for $TOTAL_MB MB RAM)
[www]
pm = dynamic
pm.max_children = $MAX_CHILDREN
pm.start_servers = $START_SERVERS
pm.min_spare_servers = $MIN_SPARE
pm.max_spare_servers = $MAX_SPARE
pm.max_requests = 1000
request_terminate_timeout = 30s
POOLEOF

    cat > "$PHP_FPM_DIR/conf.d/99-countdown-opcache.ini" << OPCACHEEOF
; StackPilot countdown-timer OPcache tuning
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.validate_timestamps=0
opcache.revalidate_freq=0
opcache.fast_shutdown=1
opcache.jit_buffer_size=0
realpath_cache_size=4096K
realpath_cache_ttl=600
OPCACHEEOF

    systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || true
    echo "  pool: max_children=$MAX_CHILDREN (RAM=${TOTAL_MB}MB)"
    echo "  opcache: validate_timestamps=0 (run: systemctl reload php${PHP_VER}-fpm after deploy)"
else
    echo "  PHP-FPM dir not found at $PHP_FPM_DIR — skipping tuning"
fi

# ── 5. Cache cleanup cron ────────────────────────────────────────────────────

echo "[5/6] Setting up cache cleanup cron..."
cat > /etc/cron.d/timer-gif-cache << 'CRONEOF'
# Countdown Timer GIF cache cleanup
* * * * * www-data find /var/cache/timer-gif/ev -name "*.gif" -mmin +5 -delete 2>/dev/null
0 */4 * * * www-data find /var/cache/timer-gif/ab -name "*.gif" -mmin +1440 -delete 2>/dev/null
*/5 * * * * www-data find /var/cache/timer-gif/ratelimit -type f -mmin +10 -delete 2>/dev/null
0 */6 * * * www-data php -r "require '/var/www/countdown-timer/src/UidStore.php'; UidStore::cleanup();" 2>/dev/null
0 3 * * * www-data php -r "require '/var/www/countdown-timer/src/ApiKeyAuth.php'; ApiKeyAuth::cleanupCounters();" 2>/dev/null
0 */6 * * * www-data find /var/cache/timer-gif -type d -empty -delete 2>/dev/null
CRONEOF

# ── 6. Cloudflare-only ingress (anti CF-Connecting-IP spoof) ────────────────

# Without this, an attacker who hits the origin IP directly can spoof the
# CF-Connecting-IP header and bypass per-IP rate limiting. The snippet
# generates a Caddy allowlist of Cloudflare IP ranges; sp-cf-lock injects
# `import cf-only` into a site block.

echo "[6/6] Installing Cloudflare allowlist tooling..."
mkdir -p /etc/caddy/conf.d /etc/caddy/snippets

build_cf_snippet() {
    local v4_raw v6_raw v4 v6
    v4_raw=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null)
    v6_raw=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null)
    if [ -z "$v4_raw" ] || [ -z "$v6_raw" ]; then
        return 1
    fi
    v4=$(echo "$v4_raw" | tr '\n' ' ')
    v6=$(echo "$v6_raw" | tr '\n' ' ')
    cat > /etc/caddy/conf.d/_cf-only-snippet.caddy << SNIPEOF
# Auto-generated by stackpilot countdown-timer install. Refreshed by cron.
# Use inside a site block: \`import cf-only\`
(cf-only) {
    @notcf not remote_ip $v4 $v6
    respond @notcf "Forbidden" 403
}
SNIPEOF
    # Also write the CIDR list for PHP RateLimiter (CloudflareIps validates
    # REMOTE_ADDR before trusting CF-Connecting-IP).
    {
        echo "# Cloudflare IP ranges, refreshed $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "$v4_raw"
        echo "$v6_raw"
    } > /var/cache/timer-gif/cf-ips.txt
    chown www-data:www-data /var/cache/timer-gif/cf-ips.txt 2>/dev/null || true
    return 0
}
if build_cf_snippet; then
    systemctl reload caddy 2>/dev/null || true
else
    echo "  WARN: failed to fetch Cloudflare IP ranges (snippet not written, PHP will use bundled fallback)"
fi

# Weekly refresh — CF ranges rotate occasionally
cat > /etc/cron.weekly/cf-ip-refresh << 'WCRON'
#!/bin/sh
v4_raw=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v4)
v6_raw=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v6)
[ -z "$v4_raw" ] || [ -z "$v6_raw" ] && exit 0
v4=$(echo "$v4_raw" | tr '\n' ' ')
v6=$(echo "$v6_raw" | tr '\n' ' ')
cat > /etc/caddy/conf.d/_cf-only-snippet.caddy <<EOF
(cf-only) {
    @notcf not remote_ip $v4 $v6
    respond @notcf "Forbidden" 403
}
EOF
{
    echo "# Cloudflare IP ranges, refreshed $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "$v4_raw"
    echo "$v6_raw"
} > /var/cache/timer-gif/cf-ips.txt
chown www-data:www-data /var/cache/timer-gif/cf-ips.txt 2>/dev/null || true
systemctl reload caddy 2>/dev/null || true
WCRON
chmod +x /etc/cron.weekly/cf-ip-refresh

# Helper: inject `import cf-only` into an existing site block
cat > /usr/local/bin/sp-cf-lock << 'SPCFEOF'
#!/bin/bash
# sp-cf-lock <domain>
# Adds `import cf-only` to the Caddy site block for <domain>, so only
# Cloudflare IPs can reach the origin. Idempotent.
set -e
DOMAIN="${1:?usage: sp-cf-lock <domain>}"
PRIMARY="${DOMAIN%%,*}"
PRIMARY="${PRIMARY// /}"
PRIMARY="${PRIMARY#http://}"
PRIMARY="${PRIMARY#https://}"
PRIMARY="${PRIMARY//\//_}"
FILE="/etc/caddy/conf.d/$PRIMARY.caddy"
if [ ! -f "$FILE" ]; then
    echo "ERROR: $FILE not found. Deploy with sp-expose first." >&2
    exit 1
fi
if [ ! -f /etc/caddy/conf.d/_cf-only-snippet.caddy ]; then
    echo "ERROR: cf-only snippet missing. Re-run install.sh." >&2
    exit 1
fi
if grep -q "import cf-only" "$FILE"; then
    echo "Already locked: $FILE"
    exit 0
fi
# Insert `import cf-only` on the line after the opening brace of $DOMAIN block.
# Caddy block header may be exactly DOMAIN, or http://DOMAIN, or DOMAIN, alt.example.com
DOMAIN_ESC=$(printf '%s\n' "$DOMAIN" | sed 's/[].[^$*\/]/\\&/g')
sed -i "/^\(http:\/\/\)\?${DOMAIN_ESC}\([[:space:],{]\|$\).*{$/a\\    import cf-only" "$FILE"
if ! grep -q "import cf-only" "$FILE"; then
    echo "ERROR: could not patch $FILE — check the block header format." >&2
    exit 1
fi
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || {
    echo "ERROR: Caddy validation failed after patch. Restoring." >&2
    sed -i "/    import cf-only/d" "$FILE"
    exit 1
}
systemctl reload caddy
echo "OK: $DOMAIN locked to Cloudflare IPs only."
SPCFEOF
chmod +x /usr/local/bin/sp-cf-lock

# ── Signal to deploy.sh: PHP app with webroot ───────────────────────────────

# deploy.sh reads this to configure Caddy with sp-expose in PHP mode
echo "$WEB_ROOT" > /tmp/countdown-timer_webroot
echo "php" > /tmp/countdown-timer_mode

# Post-deploy hook: if domain type is cloudflare, lock to CF IPs after sp-expose runs
if [ "${DOMAIN_TYPE:-}" = "cloudflare" ]; then
    echo "$DOMAIN" > /tmp/countdown-timer_cf_lock_pending
fi

echo ""
echo "=== Countdown Timer Installed ==="
echo ""
echo "  Files:     $WEB_ROOT"
echo "  Cache:     $CACHE_DIR"
echo ""
echo "  Next: configure domain (deploy.sh will do this automatically)"
echo "  Then: open https://YOUR_DOMAIN/ to see the landing page"
if [ "${DOMAIN_TYPE:-}" = "cloudflare" ]; then
    echo ""
    echo "  IMPORTANT: After deploy completes, lock origin to Cloudflare IPs:"
    echo "    ssh \$SSH_ALIAS 'sp-cf-lock $DOMAIN'"
    echo "  Without this, attackers hitting the IP directly can spoof"
    echo "  CF-Connecting-IP and bypass per-IP rate limiting."
fi
echo ""
