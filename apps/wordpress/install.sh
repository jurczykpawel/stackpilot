#!/bin/bash

# StackPilot - WordPress (Performance Edition)
# The world's most popular CMS. Blog, shop, portfolio - anything.
# https://wordpress.org
# Author: Paweł (Lazy Engineer)
#
# IMAGE_SIZE_MB=550  # wordpress:fpm-alpine+redis (~250MB) + nginx:alpine (~40MB) + redis:alpine (~30MB)
#
# Performance stack:
#   wordpress:php8.3-fpm-alpine (PHP-FPM, not Apache)
#   + nginx:alpine (static files, gzip, FastCGI cache)
#   + OPcache + JIT (2-3x faster PHP)
#   + FPM ondemand (dynamic tuning based on RAM)
#   + Security headers + hardening
#
# Two database modes:
#   1. MySQL (default) - external MySQL or your own
#      deploy.sh automatically detects MySQL need and asks for credentials
#   2. SQLite - WP_DB_MODE=sqlite, zero DB configuration
#      Ideal for simple blogs on a 1GB VPS
#
# Environment variables:
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS - from deploy.sh (MySQL mode)
#   WP_DB_MODE - "mysql" (default) or "sqlite"
#   DOMAIN - domain (optional)
#   WP_REDIS (optional): auto|external|bundled (default: auto)
#   REDIS_PASS (optional): password for external Redis

set -e

PORT=${PORT:-8080}

# =============================================================================
# MULTI-INSTANCE: instance name from domain (GateFlow pattern)
# =============================================================================
# blog.example.com → wordpress-blog
# shop.example.com → wordpress-shop
# Auto-cytrus (__CYTRUS_PENDING__) / no domain → wordpress (no suffix)
#
# NOTE: Auto-cytrus without a specific domain = SINGLE INSTANCE only!
# For multiple WordPress sites you must provide specific domains.

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ] && [[ "$DOMAIN" != *"__CYTRUS_PENDING__"* ]]; then
    INSTANCE_NAME="${DOMAIN%%.*}"
else
    INSTANCE_NAME=""
fi

if [ -n "$INSTANCE_NAME" ]; then
    APP_NAME="wordpress-${INSTANCE_NAME}"
else
    APP_NAME="wordpress"
fi

STACK_DIR="/opt/stacks/$APP_NAME"

# Prevent overwriting existing installation
if [ -z "$INSTANCE_NAME" ] && [ -d "$STACK_DIR" ] && [ -f "$STACK_DIR/docker-compose.yaml" ]; then
    echo "❌ WordPress is already installed in $STACK_DIR"
    echo ""
    echo "   Each additional WordPress site requires its own domain."
    echo "   Provide a domain (or subdomain), and WordPress will install separately:"
    echo ""
    echo "   Examples:"
    echo "     --domain=blog.example.com    → /opt/stacks/wordpress-blog/"
    echo "     --domain=shop.example.com    → /opt/stacks/wordpress-shop/"
    echo "     --domain=news.example.com    → /opt/stacks/wordpress-news/"
    echo ""
    echo "   If you want to remove the current installation:"
    echo "     cd $STACK_DIR && docker compose down -v && rm -rf $STACK_DIR"
    exit 1
fi

echo "--- 📝 WordPress Setup (Performance Edition) ---"
echo ""

WP_DB_MODE="${WP_DB_MODE:-mysql}"

# =============================================================================
# 1. RAM DETECTION → PHP-FPM TUNING
# =============================================================================

TOTAL_RAM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "1024")

if [ "$TOTAL_RAM" -ge 2000 ]; then
    FPM_MAX_CHILDREN=15
    WP_MEMORY="256M"
    NGINX_MEMORY="64M"
    echo "✅ RAM: ${TOTAL_RAM}MB → profile: large (FPM: 15 workers)"
elif [ "$TOTAL_RAM" -ge 1000 ]; then
    FPM_MAX_CHILDREN=8
    WP_MEMORY="256M"
    NGINX_MEMORY="48M"
    echo "✅ RAM: ${TOTAL_RAM}MB → profile: medium (FPM: 8 workers)"
else
    FPM_MAX_CHILDREN=4
    WP_MEMORY="192M"
    NGINX_MEMORY="32M"
    echo "✅ RAM: ${TOTAL_RAM}MB → profile: light (FPM: 4 workers)"
fi

# =============================================================================
# 1a. REDIS DETECTION (external vs bundled)
# =============================================================================
# WP_REDIS=external  → use existing on host (localhost:6379)
# WP_REDIS=bundled   → always bundle redis:alpine in compose
# WP_REDIS=auto      → auto-detect (default)

source /opt/stackpilot/lib/redis-detect.sh 2>/dev/null || true
if type detect_redis &>/dev/null; then
    detect_redis "${WP_REDIS:-auto}" "redis"
else
    # Fallback if lib unavailable
    REDIS_HOST="redis"
    echo "✅ Redis: bundled (lib/redis-detect.sh unavailable)"
fi

# Shared Redis: if bundled was selected (no Redis on host),
# install a shared Redis container instead of bundling one per stack.
# Saves ~96MB RAM per additional WordPress instance.
if [ "$REDIS_HOST" = "redis" ]; then
    REDIS_SHARED_DIR="/opt/stacks/redis-shared"
    if [ ! -f "$REDIS_SHARED_DIR/docker-compose.yaml" ]; then
        echo "📦 Installing shared Redis (for multiple WP sites)..."
        sudo mkdir -p "$REDIS_SHARED_DIR"
        cat <<'REDISEOF' | sudo tee "$REDIS_SHARED_DIR/docker-compose.yaml" > /dev/null
services:
  redis:
    image: redis:alpine
    restart: always
    ports:
      - "127.0.0.1:6379:6379"
    command: redis-server --maxmemory 96mb --maxmemory-policy allkeys-lru --save 60 1 --loglevel warning
    volumes:
      - ./data:/data
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "2"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 128M
REDISEOF
        sudo docker compose -f "$REDIS_SHARED_DIR/docker-compose.yaml" up -d
        sleep 2
    fi
    REDIS_HOST="host-gateway"
    echo "✅ Redis: shared (127.0.0.1:6379)"
fi

# Redis password (user provides via REDIS_PASS env var)
REDIS_PASS="${REDIS_PASS:-}"
if [ -n "$REDIS_PASS" ] && [ "$REDIS_HOST" = "host-gateway" ]; then
    echo "   🔑 Redis password: set"
fi

# Domain
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "✅ Domain: $DOMAIN"
elif [ "$DOMAIN" = "-" ]; then
    echo "✅ Domain: automatic (Cytrus)"
else
    echo "⚠️  No domain - use --domain=... or access via SSH tunnel"
fi

# Port binding: Cytrus requires 0.0.0.0, Cloudflare/local → 127.0.0.1 (more secure)
if [ "${DOMAIN_TYPE:-}" = "cytrus" ]; then
    BIND_ADDR=""
else
    BIND_ADDR="127.0.0.1:"
fi

# =============================================================================
# 2. DATABASE VALIDATION
# =============================================================================

if [ "$WP_DB_MODE" = "sqlite" ]; then
    echo "✅ Mode: WordPress + SQLite (lightweight, no MySQL)"
else
    echo "✅ Mode: WordPress + MySQL"
    if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
        echo "❌ Missing MySQL credentials!"
        echo "   Required: DB_HOST, DB_USER, DB_PASS, DB_NAME"
        echo ""
        echo "   Use deploy.sh - it configures the database automatically:"
        echo "   ./local/deploy.sh wordpress --ssh=mikrus"
        echo ""
        echo "   Or use SQLite mode (no MySQL):"
        echo "   WP_DB_MODE=sqlite ./local/deploy.sh wordpress --ssh=mikrus"
        exit 1
    fi
    DB_PORT=${DB_PORT:-3306}
    DB_NAME=${DB_NAME:-$APP_NAME}
    echo "   Host: $DB_HOST:$DB_PORT | User: $DB_USER | DB: $DB_NAME"

    # Check if the database has existing WordPress tables
    _db_query() {
        if command -v mysql &>/dev/null; then
            mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "$1" -sN 2>/dev/null
        elif command -v mariadb &>/dev/null; then
            mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "$1" -sN 2>/dev/null
        elif command -v docker &>/dev/null; then
            docker run --rm mariadb:lts mariadb --skip-ssl -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "$1" -sN 2>/dev/null
        else
            return 1
        fi
    }

    WP_TABLE_COUNT=$(_db_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name LIKE 'wp_%'") || true
    if [ -n "$WP_TABLE_COUNT" ] && [ "$WP_TABLE_COUNT" -gt 0 ]; then
        echo ""
        echo "⚠️  Database '$DB_NAME' contains $WP_TABLE_COUNT WordPress tables!"
        echo "   WordPress will connect to existing data (old site)."
        echo "   The setup wizard will NOT appear — the old site will load."
        echo ""
        if [ -t 0 ] && [ "$YES_MODE" != true ]; then
            read -p "Continue with the existing database? [y/N]: " DB_CONFIRM
            if [[ ! "$DB_CONFIRM" =~ ^[Yy]$ ]]; then
                echo "Cancelled."
                echo "   To clear the database: log in to your database panel,"
                echo "   and delete the wp_* tables."
                echo "   If you don't know how — ask the AI agent, it will help you step by step."
                exit 1
            fi
        else
            echo "   ℹ️  --yes mode: continuing (existing data will be preserved)"
        fi
    fi
fi
echo ""

# =============================================================================
# 3. PREPARE DIRECTORIES
# =============================================================================

sudo mkdir -p "$STACK_DIR"/{config,wp-content,nginx-cache,redis-data}
cd "$STACK_DIR"

# Save Redis config for wp-init.sh
echo "$REDIS_HOST" | sudo tee "$STACK_DIR/.redis-host" > /dev/null
if [ -n "$REDIS_PASS" ]; then
    echo "$REDIS_PASS" | sudo tee "$STACK_DIR/.redis-pass" > /dev/null
    sudo chmod 600 "$STACK_DIR/.redis-pass"
fi

# =============================================================================
# 3a. DOCKERFILE (wordpress + redis extension + WP-CLI)
# =============================================================================

echo "⚙️  Generating Dockerfile (PHP redis extension + WP-CLI)..."

cat <<'DOCKERFILE_EOF' | sudo tee "$STACK_DIR/Dockerfile" > /dev/null
FROM wordpress:php8.3-fpm-alpine

# PHP redis extension (for Redis Object Cache)
RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .build-deps

# MySQL client (for WP-CLI db check/export/import)
RUN apk add --no-cache mysql-client \
    && printf '[client]\nssl=0\n' > /etc/my.cnf.d/disable-ssl.cnf

# WP-CLI (manage WordPress from the command line)
RUN curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp
DOCKERFILE_EOF

# SQLite: download plugin
if [ "$WP_DB_MODE" = "sqlite" ]; then
    sudo mkdir -p "$STACK_DIR/wp-content/database"
    echo "📥 Downloading WordPress SQLite Database Integration plugin..."
    SQLITE_PLUGIN_URL="https://github.com/WordPress/sqlite-database-integration/archive/refs/heads/main.zip"
    TEMP_ZIP=$(mktemp)
    if curl -fsSL "$SQLITE_PLUGIN_URL" -o "$TEMP_ZIP"; then
        sudo mkdir -p "$STACK_DIR/wp-content/mu-plugins"
        sudo unzip -qo "$TEMP_ZIP" -d "$STACK_DIR/wp-content/mu-plugins/"
        sudo mv "$STACK_DIR/wp-content/mu-plugins/sqlite-database-integration-main" \
                "$STACK_DIR/wp-content/mu-plugins/sqlite-database-integration" 2>/dev/null || true
        sudo cp "$STACK_DIR/wp-content/mu-plugins/sqlite-database-integration/db.copy" \
                "$STACK_DIR/wp-content/db.php"
        echo "✅ SQLite plugin installed"
    else
        echo "❌ Failed to download SQLite plugin"
        rm -f "$TEMP_ZIP"
        exit 1
    fi
    rm -f "$TEMP_ZIP"
fi

# =============================================================================
# 4. PHP CONFIGURATION - OPcache + JIT + Security
# =============================================================================

echo "⚙️  Generating PHP configuration (OPcache + JIT + security)..."

cat <<'OPCACHE_EOF' | sudo tee "$STACK_DIR/config/php-opcache.ini" > /dev/null
[opcache]
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=0
opcache.validate_timestamps=0
opcache.fast_shutdown=1
opcache.max_wasted_percentage=10
opcache.jit=1255
opcache.jit_buffer_size=64M
OPCACHE_EOF

cat <<'PHPINI_EOF' | sudo tee "$STACK_DIR/config/php-performance.ini" > /dev/null
[PHP]
memory_limit = 256M
max_execution_time = 30
max_input_time = 60
post_max_size = 64M
upload_max_filesize = 64M
expose_php = Off
display_errors = Off
log_errors = On
error_log = /dev/stderr

; Compression (at PHP level, Nginx also compresses)
zlib.output_compression = On
zlib.output_compression_level = 4

; Realpath cache - WordPress has a deep file structure
; Default 16k is too small → 4096k eliminates thousands of stat() calls per request
realpath_cache_size = 4096k
realpath_cache_ttl = 600

; Session security
session.cookie_secure = On
session.cookie_httponly = On
session.cookie_samesite = Lax

; Don't send Cache-Control: no-store on session_start()
; Cache control is handled by Nginx (FastCGI cache + skip_cache rules)
session.cache_limiter =
PHPINI_EOF

# =============================================================================
# 5. PHP-FPM CONFIGURATION (ondemand, RAM-based tuning)
# =============================================================================

echo "⚙️  Generating PHP-FPM configuration (ondemand, max_children=$FPM_MAX_CHILDREN)..."

cat <<FPM_EOF | sudo tee "$STACK_DIR/config/www.conf" > /dev/null
[www]
user = www-data
group = www-data
listen = 9000

pm = ondemand
pm.max_children = $FPM_MAX_CHILDREN
pm.process_idle_timeout = 10s
pm.max_requests = 500

request_slowlog_timeout = 10s
slowlog = /proc/self/fd/2
FPM_EOF

# =============================================================================
# 6. NGINX CONFIGURATION (static files, gzip, FastCGI cache, security headers)
# =============================================================================

echo "⚙️  Generating Nginx configuration (gzip, FastCGI cache, security headers)..."

cat <<'NGINX_EOF' | sudo tee "$STACK_DIR/config/nginx.conf" > /dev/null
worker_processes auto;
worker_rlimit_nofile 8192;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Performance
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    client_max_body_size 64M;
    server_tokens off;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_types
        text/plain
        text/css
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/xml
        image/svg+xml
        font/woff2;

    # Open file cache - reduces disk I/O by ~80% for static files
    open_file_cache max=10000 inactive=5m;
    open_file_cache_valid 2m;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # FastCGI cache (24h for pages, skip admin/login/API)
    fastcgi_cache_path /var/cache/nginx levels=1:2
        keys_zone=wordpress:10m max_size=256m inactive=24h;
    fastcgi_temp_path /tmp/nginx_fastcgi_temp;
    fastcgi_cache_key "$scheme$request_method$host$request_uri";
    fastcgi_cache_use_stale error timeout updating http_500 http_503;
    fastcgi_cache_lock on;
    fastcgi_cache_lock_timeout 5s;
    fastcgi_cache_background_update on;

    # Rate limiting - brute force protection (without burdening PHP)
    limit_req_zone $binary_remote_addr zone=wp_login:10m rate=1r/s;

    # WebP: serve converted images from uploads-webpc/ when browser supports WebP
    map $http_accept $webp_suffix {
        default "";
        "~*webp" ".webp";
    }

    server {
        listen 80;
        server_name _;
        root /var/www/html;
        index index.php;

        # Security headers
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

        # WebP: images in wp-content — serve WebP version if it exists
        location ~* /wp-content/.+\.(jpe?g|png|gif)$ {
            add_header Vary Accept;
            expires 365d;
            add_header Cache-Control "public, immutable";
            access_log off;
            try_files /wp-content/uploads-webpc/$uri$webp_suffix $uri =404;
        }

        # Static files - cache 1 year, served without PHP
        location ~* \.(ico|webp|avif|css|js|svg|woff|woff2|ttf|eot)$ {
            expires 365d;
            add_header Cache-Control "public, immutable";
            access_log off;
        }

        # wp-login.php - rate limiting (1 req/s, burst 3)
        location = /wp-login.php {
            limit_req zone=wp_login burst=3 nodelay;
            limit_req_status 429;

            fastcgi_pass wordpress:9000;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;
            fastcgi_param HTTPS $http_x_forwarded_proto if_not_empty;
        }

        # Block xmlrpc.php - DDoS and brute force vector, rarely used
        location = /xmlrpc.php {
            deny all;
            access_log off;
            log_not_found off;
        }

        # Block user enumeration (?author=N)
        if ($args ~* "author=\d+") {
            return 403;
        }

        # Skip cache rules
        set $skip_cache 0;

        # Admin, login, API, cron - always fresh
        if ($request_uri ~* "/wp-admin/|/wp-login\.php|/wp-json/|wp-.*\.php") {
            set $skip_cache 1;
        }

        # Logged-in users + WooCommerce cart - always fresh
        if ($http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_logged_in|woocommerce_cart_hash|woocommerce_items_in_cart") {
            set $skip_cache 1;
        }

        # WooCommerce dynamic pages - always fresh
        if ($request_uri ~* "/cart/|/checkout/|/my-account/|/addons/") {
            set $skip_cache 1;
        }

        # POST requests - don't cache
        if ($request_method = POST) {
            set $skip_cache 1;
        }

        # PHP via FastCGI + cache
        location ~ \.php$ {
            try_files $uri =404;
            fastcgi_split_path_info ^(.+\.php)(/.+)$;
            fastcgi_pass wordpress:9000;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;

            # Pass HTTPS info (for reverse proxy fix)
            fastcgi_param HTTPS $http_x_forwarded_proto if_not_empty;

            # FastCGI buffers - optimal for WordPress responses
            fastcgi_buffers 16 16k;
            fastcgi_buffer_size 32k;
            fastcgi_keep_conn on;

            # FastCGI cache
            fastcgi_cache wordpress;
            fastcgi_cache_valid 200 24h;
            fastcgi_cache_bypass $skip_cache;
            fastcgi_ignore_headers Cache-Control Expires Set-Cookie;
            fastcgi_no_cache $skip_cache;
            add_header X-FastCGI-Cache $upstream_cache_status;
        }

        location / {
            try_files $uri $uri/ /index.php?$args;
        }

        # Block access to sensitive files
        location ~ /\.(ht|git|env) { deny all; }
        location = /wp-config.php { deny all; }
        location ~* /(?:uploads|files)/.*\.php$ { deny all; }
    }
}
NGINX_EOF

# =============================================================================
# 7. DOCKER-COMPOSE (FPM + Nginx)
# =============================================================================

echo "⚙️  Generating docker-compose.yaml..."

# --- WordPress service (common base) ---
WP_ENV_BLOCK=""
if [ "$WP_DB_MODE" != "sqlite" ]; then
    WP_ENV_BLOCK="    environment:
      - WORDPRESS_DB_HOST=${DB_HOST}:${DB_PORT}
      - WORDPRESS_DB_USER=${DB_USER}
      - WORDPRESS_DB_PASSWORD=${DB_PASS}
      - WORDPRESS_DB_NAME=${DB_NAME}"
fi

# --- Redis: bundled vs external ---
WP_DEPENDS=""
WP_EXTRA_HOSTS=""
REDIS_SERVICE=""

if [ "$REDIS_HOST" = "redis" ]; then
    # Bundled Redis
    WP_DEPENDS="    depends_on:
      - redis"
    REDIS_SERVICE="
  redis:
    image: redis:alpine
    restart: always
    command: redis-server --maxmemory 64mb --maxmemory-policy allkeys-lru --save 60 1 --loglevel warning
    volumes:
      - ./redis-data:/data
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: \"5m\"
        max-file: \"2\"
    healthcheck:
      test: [\"CMD\", \"redis-cli\", \"ping\"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 96M"
else
    # External Redis - connect to host
    WP_EXTRA_HOSTS="    extra_hosts:
      - \"host-gateway:host-gateway\""
fi

cat <<EOF | sudo tee docker-compose.yaml > /dev/null
services:
  wordpress:
    build: .
    restart: always
$WP_ENV_BLOCK
    volumes:
      - ./wp-content:/var/www/html/wp-content
      - ./config/php-opcache.ini:/usr/local/etc/php/conf.d/opcache.ini:ro
      - ./config/php-performance.ini:/usr/local/etc/php/conf.d/performance.ini:ro
      - ./config/www.conf:/usr/local/etc/php-fpm.d/www.conf:ro
      - ./nginx-cache:/var/cache/nginx
      - ${APP_NAME}-html:/var/www/html
    tmpfs:
      - /tmp:size=128M,mode=1777
$WP_DEPENDS
$WP_EXTRA_HOSTS
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "php -v > /dev/null"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: $WP_MEMORY
$REDIS_SERVICE

  nginx:
    image: nginx:alpine
    restart: always
    ports:
      - "${BIND_ADDR}$PORT:80"
    volumes:
      - ./config/nginx.conf:/etc/nginx/nginx.conf:ro
      - /dev/null:/etc/nginx/conf.d/default.conf:ro
      - ./nginx-cache:/var/cache/nginx
      - ${APP_NAME}-html:/var/www/html:ro
      - ./wp-content:/var/www/html/wp-content:ro
    depends_on:
      - wordpress
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD", "wget", "-qO/dev/null", "--spider", "http://127.0.0.1/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: $NGINX_MEMORY

volumes:
  ${APP_NAME}-html:
EOF

# Clean empty lines from YAML (from empty conditional blocks)
sudo sed -i '/^$/{ N; /^\n$/d; }' docker-compose.yaml

# =============================================================================
# 8. WP-INIT.SH (post-install: HTTPS fix, wp-cron, performance defines)
# =============================================================================

cat <<'INITEOF' | sudo tee "$STACK_DIR/wp-init.sh" > /dev/null
#!/bin/bash
# WordPress Performance Init — automatically run by install.sh
# Idempotent — safe to re-run
# Generates wp-config-performance.php + adds require_once to wp-config.php
# Redis Object Cache plugin via WP-CLI

cd "$(dirname "$0")"
STACK_DIR="$(pwd)"

QUIET=false
RETRY_MODE=false
RETRY_COUNT_FILE="$STACK_DIR/.wp-init-retries"
MAX_RETRIES=30

if [ "$1" = "--retry" ]; then
    QUIET=true
    RETRY_MODE=true
    # Retry counter — remove cron after MAX_RETRIES (30 min)
    COUNT=0
    [ -f "$RETRY_COUNT_FILE" ] && COUNT=$(cat "$RETRY_COUNT_FILE")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$RETRY_COUNT_FILE"
    if [ "$COUNT" -ge "$MAX_RETRIES" ]; then
        crontab -l 2>/dev/null | grep -v "wp-init-retry" | crontab -
        rm -f "$RETRY_COUNT_FILE"
        exit 0
    fi
fi

log() { [ "$QUIET" = false ] && echo "$@"; }

WP_CONFIG="/var/www/html/wp-config.php"
PERF_CONFIG="/var/www/html/wp-config-performance.php"
CONTAINER=$(docker compose ps -q wordpress 2>/dev/null | head -1)

if [ -z "$CONTAINER" ]; then
    log "❌ WordPress container is not running"
    exit 1
fi

# --- Part 1: wp-config-performance.php (does not require DB tables) ---

if ! docker exec "$CONTAINER" test -f "$WP_CONFIG"; then
    log "⏳ WordPress hasn't generated wp-config.php yet"
    log "   Open the site in a browser, and optimizations will apply automatically."
    if ! crontab -l 2>/dev/null | grep -q "wp-init-retry"; then
        RETRY="* * * * * $STACK_DIR/wp-init.sh --retry > /dev/null 2>&1 # wp-init-retry"
        (crontab -l 2>/dev/null; echo "$RETRY") | crontab -
        log "   ⏰ Retrying every minute until wp-config.php is ready"
    fi
    exit 0
fi

log "🔧 Optimizing wp-config.php..."

# Redis config
REDIS_HOST="redis"
if [ -f "$STACK_DIR/.redis-host" ]; then
    REDIS_HOST=$(cat "$STACK_DIR/.redis-host")
fi
REDIS_PASS=""
if [ -f "$STACK_DIR/.redis-pass" ]; then
    REDIS_PASS=$(cat "$STACK_DIR/.redis-pass")
fi
if [ "$REDIS_HOST" = "host-gateway" ]; then
    WP_REDIS_ADDR="host-gateway"
else
    WP_REDIS_ADDR="$REDIS_HOST"
fi

REDIS_PASS_LINE=""
if [ -n "$REDIS_PASS" ]; then
    REDIS_PASS_LINE="defined('WP_REDIS_PASSWORD') || define('WP_REDIS_PASSWORD', '$REDIS_PASS');"
fi

# Redis prefix = stack name (unique per instance, prevents key collisions)
REDIS_PREFIX="$(basename "$STACK_DIR")"

# Generate wp-config-performance.php (always overwrites — idempotent)
cat <<PERFEOF | docker exec -i "$CONTAINER" tee "$PERF_CONFIG" > /dev/null
<?php
// StackPilot — WordPress Performance Config
// Generated by wp-init.sh — DO NOT edit manually

// HTTPS behind reverse proxy (Cytrus/Caddy/Cloudflare)
if (isset(\$_SERVER["HTTP_X_FORWARDED_PROTO"]) && \$_SERVER["HTTP_X_FORWARDED_PROTO"] === "https") {
    \$_SERVER["HTTPS"] = "on";
}

// Performance & Security (defined() guard — Docker env vars may define the same constants)
defined('DISABLE_WP_CRON')    || define('DISABLE_WP_CRON', true);
defined('WP_POST_REVISIONS')  || define('WP_POST_REVISIONS', 5);
defined('EMPTY_TRASH_DAYS')   || define('EMPTY_TRASH_DAYS', 14);
defined('WP_MEMORY_LIMIT')    || define('WP_MEMORY_LIMIT', '256M');
defined('WP_MAX_MEMORY_LIMIT')|| define('WP_MAX_MEMORY_LIMIT', '512M');
defined('AUTOSAVE_INTERVAL')  || define('AUTOSAVE_INTERVAL', 300);
defined('DISALLOW_FILE_EDIT') || define('DISALLOW_FILE_EDIT', true);

// Redis Object Cache
defined('WP_REDIS_HOST')   || define('WP_REDIS_HOST', '$WP_REDIS_ADDR');
defined('WP_REDIS_PORT')   || define('WP_REDIS_PORT', 6379);
defined('WP_REDIS_PREFIX') || define('WP_REDIS_PREFIX', '${REDIS_PREFIX}:');
${REDIS_PASS_LINE}
defined('WP_CACHE')        || define('WP_CACHE', true);
PERFEOF

docker exec "$CONTAINER" chown www-data:www-data "$PERF_CONFIG"
log "   ✅ Generated wp-config-performance.php"

# Add require_once to wp-config.php (one-time)
if ! docker exec "$CONTAINER" grep -q "wp-config-performance.php" "$WP_CONFIG"; then
    docker exec "$CONTAINER" sed -i '/^<?php/a\require_once __DIR__ . "/wp-config-performance.php";' "$WP_CONFIG"
    log "   ✅ Added require_once to wp-config.php"
else
    log "   ℹ️  require_once already exists in wp-config.php"
fi

# --- Part 2: WP-CLI (requires DB tables — may not work immediately) ---

REDIS_OK=false
if docker exec "$CONTAINER" test -f /usr/local/bin/wp; then
    # Check if DB is ready (tables exist)
    if docker exec -u www-data "$CONTAINER" wp core is-installed --path=/var/www/html > /dev/null 2>&1; then
        if ! docker exec -u www-data "$CONTAINER" wp plugin is-installed redis-cache --path=/var/www/html 2>/dev/null; then
            log "   📥 Installing Redis Object Cache plugin..."
            if docker exec -u www-data "$CONTAINER" wp plugin install redis-cache --activate --path=/var/www/html 2>/dev/null; then
                log "   ✅ Redis Object Cache plugin installed and activated"
                REDIS_OK=true
            fi
        else
            docker exec -u www-data "$CONTAINER" wp plugin activate redis-cache --path=/var/www/html 2>/dev/null || true
            REDIS_OK=true
            log "   ℹ️  Redis Object Cache plugin already installed"
        fi

        if [ "$REDIS_OK" = true ]; then
            docker exec -u www-data "$CONTAINER" wp redis enable --path=/var/www/html --force 2>/dev/null \
                && log "   ✅ Redis Object Cache enabled (drop-in active)" \
                || log "   ⚠️  Failed to enable Redis drop-in"
        fi

        # Nginx Helper — automatic FastCGI cache purge on content edit
        if ! docker exec -u www-data "$CONTAINER" wp plugin is-installed nginx-helper --path=/var/www/html 2>/dev/null; then
            log "   📥 Installing Nginx Helper plugin (cache purge)..."
            if docker exec -u www-data "$CONTAINER" wp plugin install nginx-helper --activate --path=/var/www/html 2>/dev/null; then
                log "   ✅ Nginx Helper plugin installed"
            fi
        else
            docker exec -u www-data "$CONTAINER" wp plugin activate nginx-helper --path=/var/www/html 2>/dev/null || true
            log "   ℹ️  Nginx Helper plugin already installed"
        fi
        # Configuration: file-based purge, path /var/cache/nginx
        docker exec -u www-data "$CONTAINER" wp option update rt_wp_nginx_helper_options \
            '{"enable_purge":"1","cache_method":"enable_fastcgi","purge_method":"unlink_files","purge_homepage_on_edit":"1","purge_homepage_on_del":"1","purge_archive_on_edit":"1","purge_archive_on_del":"1","purge_archive_on_new_comment":"1","purge_archive_on_deleted_comment":"1","purge_page_on_mod":"1","purge_page_on_new_comment":"1","purge_page_on_deleted_comment":"1","log_level":"NONE","log_filesize":"5","nginx_cache_path":"/var/cache/nginx"}' \
            --format=json --path=/var/www/html 2>/dev/null || true

        # Converter for Media — automatic image conversion to WebP
        if ! docker exec -u www-data "$CONTAINER" wp plugin is-installed webp-converter-for-media --path=/var/www/html 2>/dev/null; then
            log "   📥 Installing Converter for Media plugin (WebP)..."
            if docker exec -u www-data "$CONTAINER" wp plugin install webp-converter-for-media --activate --path=/var/www/html 2>/dev/null; then
                log "   ✅ Converter for Media plugin installed"
            fi
        else
            docker exec -u www-data "$CONTAINER" wp plugin activate webp-converter-for-media --path=/var/www/html 2>/dev/null || true
            log "   ℹ️  Converter for Media plugin already installed"
        fi
    else
        log "   ℹ️  Database not initialized yet — plugins will be installed automatically"
    fi
fi

# Add retry cron if Redis plugin was not installed
if [ "$REDIS_OK" = false ] && ! crontab -l 2>/dev/null | grep -q "wp-init-retry"; then
    RETRY="* * * * * $STACK_DIR/wp-init.sh --retry > /dev/null 2>&1 # wp-init-retry"
    (crontab -l 2>/dev/null; echo "$RETRY") | crontab -
    log "   ⏰ Redis plugin — retrying every minute until DB is ready"
fi

# Remove retry cron if Redis OK
if [ "$REDIS_OK" = true ] && crontab -l 2>/dev/null | grep -q "wp-init-retry"; then
    crontab -l 2>/dev/null | grep -v "wp-init-retry" | crontab -
    rm -f "$RETRY_COUNT_FILE"
    log "   ✅ Retry cron removed (Redis is working)"
fi

# --- Part 3: System cron and cache ---

CRON_CMD="*/5 * * * * docker exec \$(docker compose -f $STACK_DIR/docker-compose.yaml ps -q wordpress) php /var/www/html/wp-cron.php > /dev/null 2>&1"
if ! crontab -l 2>/dev/null | grep -q "wp-cron.php"; then
    (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
    log "   ✅ System cron added (every 5 min)"
else
    log "   ℹ️  System cron already exists"
fi

if [ -d "$STACK_DIR/nginx-cache" ]; then
    rm -rf "$STACK_DIR/nginx-cache"/*
    log "   ✅ FastCGI cache cleared"
fi

log ""
log "✅ All optimizations applied!"
INITEOF
sudo chmod +x "$STACK_DIR/wp-init.sh"

# Script to clear cache (useful after content updates)
cat <<'CACHEEOF' | sudo tee "$STACK_DIR/flush-cache.sh" > /dev/null
#!/bin/bash
# Clear Nginx FastCGI cache (after content/plugin updates)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$SCRIPT_DIR/nginx-cache"/*
docker compose -f "$SCRIPT_DIR/docker-compose.yaml" exec nginx nginx -s reload 2>/dev/null || true
echo "✅ FastCGI cache cleared"
CACHEEOF
sudo chmod +x "$STACK_DIR/flush-cache.sh"

# =============================================================================
# 9. LAUNCH
# =============================================================================

# Permissions for wp-content (www-data = UID 82 in alpine, 33 in debian)
# wordpress:fpm-alpine uses UID 82
sudo chown -R 82:82 "$STACK_DIR/wp-content"

echo ""
echo "🔨 Building WordPress image (redis extension + WP-CLI)..."
sudo docker compose build --quiet 2>/dev/null || sudo docker compose build

echo "🚀 Starting WordPress (FPM + Nginx + Redis)..."
sudo docker compose up -d

# Health check - build + start need more time
echo "⏳ Waiting for startup..."
source /opt/stackpilot/lib/health-check.sh 2>/dev/null || true
if type wait_for_healthy &>/dev/null; then
    wait_for_healthy "$APP_NAME" "$PORT" 60 || { echo "❌ Installation failed!"; exit 1; }
else
    for i in $(seq 1 6); do
        sleep 10
        if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
            echo "✅ WordPress is running (after $((i*10))s)"
            break
        fi
        echo "   ... $((i*10))s"
        if [ "$i" -eq 6 ]; then
            echo "❌ Failed to start within 60s!"
            sudo docker compose logs --tail 30
            exit 1
        fi
    done
fi

# =============================================================================
# 9a. AUTOMATIC OPTIMIZATIONS (wp-init.sh)
# =============================================================================

echo ""
echo "⚙️  Running wp-config.php optimizations..."
bash "$STACK_DIR/wp-init.sh" 2>&1 | sed 's/^/   /'

# Pass STACK_DIR to deploy.sh (for Cytrus placeholder update)
echo "$STACK_DIR" > /tmp/app_stack_dir

# =============================================================================
# 10. SUMMARY
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ WordPress installed! (Performance Edition)"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "-" ]; then
    echo "🔗 Open https://$DOMAIN to complete the installation"
elif [ "$DOMAIN" = "-" ]; then
    echo "🔗 Domain will be configured automatically after installation"
else
    echo "🔗 Access via SSH tunnel: ssh -L $PORT:localhost:$PORT <server>"
fi

echo ""
echo "📝 Next step:"
echo "   Open the site in a browser → WordPress setup wizard"
echo ""

echo "⚡ What was automatically optimized:"
echo "   • PHP-FPM alpine (lighter than Apache)"
echo "   • OPcache + JIT (2-3x faster PHP)"
echo "   • Redis Object Cache (-70% DB queries)"
echo "   • Nginx FastCGI cache (cache expires after 24h)"
echo "   • Gzip compression (-60-80% bandwidth)"
echo "   • Security headers + rate limiting + xmlrpc block"
echo "   • FPM ondemand ($FPM_MAX_CHILDREN workers, tuned for ${TOTAL_RAM}MB RAM)"
echo "   • HTTPS reverse proxy fix"
echo "   • System cron (instead of wp-cron, every 5 min)"
echo "   • Revision limits, memory limits, autosave"
echo ""

echo "📋 Useful commands (on server, in $STACK_DIR):"
echo "   ./flush-cache.sh       — clear Nginx cache (after content/plugin changes)"
echo "   docker compose logs -f — logs (FPM + Nginx + Redis)"
echo ""

echo "   Database mode: $WP_DB_MODE"
if [ "$WP_DB_MODE" = "sqlite" ]; then
    echo "   Database: SQLite in wp-content/database/"
else
    echo "   Database: MySQL ($DB_HOST:$DB_PORT/$DB_NAME)"
fi
