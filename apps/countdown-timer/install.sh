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
    echo "  SAVE THIS KEY - it won't be shown again!"
else
    echo "  keys.json already exists, keeping it"
fi

# ── 4. Create cache directories ─────────────────────────────────────────────

echo "[4/5] Creating cache directories..."
mkdir -p "$CACHE_DIR"/{ab,ev,uid,apikeys,ratelimit}
chown -R www-data:www-data "$CACHE_DIR"
chmod -R 755 "$CACHE_DIR"

# Set web root permissions
chown -R www-data:www-data "$WEB_ROOT"

# ── 5. Cache cleanup cron ────────────────────────────────────────────────────

echo "[5/5] Setting up cache cleanup cron..."
cat > /etc/cron.d/timer-gif-cache << 'CRONEOF'
# Countdown Timer GIF cache cleanup
* * * * * www-data find /var/cache/timer-gif/ev -name "*.gif" -mmin +5 -delete 2>/dev/null
0 */4 * * * www-data find /var/cache/timer-gif/ab -name "*.gif" -mmin +1440 -delete 2>/dev/null
*/5 * * * * www-data find /var/cache/timer-gif/ratelimit -type f -mmin +10 -delete 2>/dev/null
0 */6 * * * www-data php -r "require '/var/www/countdown-timer/src/UidStore.php'; UidStore::cleanup();" 2>/dev/null
0 3 * * * www-data php -r "require '/var/www/countdown-timer/src/ApiKeyAuth.php'; ApiKeyAuth::cleanupCounters();" 2>/dev/null
0 */6 * * * www-data find /var/cache/timer-gif -type d -empty -delete 2>/dev/null
CRONEOF

# ── Signal to deploy.sh: PHP app with webroot ───────────────────────────────

# deploy.sh reads this to configure Caddy with sp-expose in PHP mode
echo "$WEB_ROOT" > /tmp/countdown-timer_webroot
echo "php" > /tmp/countdown-timer_mode

echo ""
echo "=== Countdown Timer Installed ==="
echo ""
echo "  Files:     $WEB_ROOT"
echo "  Cache:     $CACHE_DIR"
echo ""
echo "  Next: configure domain (deploy.sh will do this automatically)"
echo "  Then: open https://YOUR_DOMAIN/ to see the landing page"
echo ""
