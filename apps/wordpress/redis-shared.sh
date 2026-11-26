#!/bin/bash

# StackPilot - shared Redis object cache for WordPress sites
# Sourced by apps/wordpress/install.sh and update.sh.
#
# The cache is published only on the Docker bridge address (what containers
# reach as "host-gateway") and requires a password kept in redis-shared/.env.

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
REDIS_SHARED_DIR="$STACKS_DIR/redis-shared"

redis_shared_password() {
    sudo sed -n 's/^REDIS_PASSWORD=//p' "$REDIS_SHARED_DIR/.env" 2>/dev/null || true
}

_redis_bridge_address() {
    local address
    address=$(sudo docker network inspect bridge --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2>/dev/null \
        | grep -E -m1 '^([0-9]+\.){3}[0-9]+$') || true
    if [ -z "$address" ]; then
        address=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    fi
    [ -n "$address" ] && echo "$address"
}

# Creates the definition, or rewrites an older one (data stays in ./data).
_redis_shared_define() {
    local compose="$REDIS_SHARED_DIR/docker-compose.yaml" address

    if [ -z "$(redis_shared_password)" ] || ! sudo grep -q 'REDIS_PASSWORD' "$compose" 2>/dev/null; then
        address=$(_redis_bridge_address) || { echo "❌ Cannot determine the Docker bridge address" >&2; return 1; }
        echo "📦 Configuring shared Redis (for multiple WP sites)..."
        sudo mkdir -p "$REDIS_SHARED_DIR"
        if [ -z "$(redis_shared_password)" ]; then
            (umask 077; echo "REDIS_PASSWORD=$(openssl rand -hex 24)" | sudo tee "$REDIS_SHARED_DIR/.env" > /dev/null)
        fi
        sudo chmod 600 "$REDIS_SHARED_DIR/.env"
        if sudo test -f "$compose"; then
            sudo cp "$compose" "$compose.bak"
        fi
        cat <<REDISEOF | sudo tee "$compose" > /dev/null
services:
  redis:
    image: redis:alpine
    restart: always
    ports:
      - "$address:6379:6379"
    command: redis-server --requirepass \${REDIS_PASSWORD} --maxmemory 96mb --maxmemory-policy allkeys-lru --save 60 1 --loglevel warning
    environment:
      - REDISCLI_AUTH=\${REDIS_PASSWORD}
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
      test: ["CMD-SHELL", "redis-cli ping | grep -q PONG"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 128M
REDISEOF
    fi
}

# Puts the password into a site's PHP config. PHP-FPM keeps the old compiled
# file until reloaded (opcache.validate_timestamps=0), so the site is not
# affected until _redis_shared_reload_site.
_redis_shared_configure_site() {
    local dir="$1" password="$2" script
    script=$(cat <<'CLIENTEOF'
f=/var/www/html/wp-config-performance.php
[ -f "$f" ] || exit 0
IFS= read -r password
awk -v q="'" -v password="$password" '
    index($0, q "WP_REDIS_PASSWORD" q) { next }
    { print }
    index($0, "define(" q "WP_REDIS_PORT" q) {
        print "defined(" q "WP_REDIS_PASSWORD" q ") || define(" q "WP_REDIS_PASSWORD" q ", " q password q ");"
    }' "$f" > "$f.new" && cat "$f.new" > "$f" && rm "$f.new" && grep -q WP_REDIS_PASSWORD "$f"
CLIENTEOF
)
    echo "🔑 Updating cache settings: $(basename "$dir")"
    (cd "$dir" && echo "$password" | sudo docker compose run --rm --no-deps -T --entrypoint sh wordpress -c "$script")
}

# .redis-pass is written last, so an interrupted run is picked up again next time.
_redis_shared_reload_site() {
    local dir="$1" password="$2"
    (
        cd "$dir" || exit 1
        if [ -n "$(sudo docker compose ps --status running -q wordpress)" ]; then
            sudo docker compose kill -s USR2 wordpress
        fi
    )
    echo "$password" | sudo tee "$dir/.redis-pass" > /dev/null
    # Owned by the invoking user: wp-init.sh (and its cron retry) reads it
    sudo chown "$(id -u):$(id -g)" "$dir/.redis-pass"
    sudo chmod 600 "$dir/.redis-pass"
}

# Other stacks that were pointed at the shared cache by URL (e.g. Postiz).
_redis_shared_url_client() {
    local dir="$1" password="$2" content old='redis://host-gateway:6379'
    content=$(sudo cat "$dir/docker-compose.yaml")
    echo "🔑 Updating cache settings: $(basename "$dir")"
    printf '%s\n' "${content//"$old"/redis://:$password@host-gateway:6379}" \
        | sudo tee "$dir/docker-compose.yaml" > /dev/null
    (
        cd "$dir" || exit 1
        if [ -n "$(sudo docker compose ps --status running -q)" ]; then
            sudo docker compose up -d
        fi
    )
}

# Brings the shared Redis and every stack using it to the current settings.
redis_shared_apply() {
    local compose="$REDIS_SHARED_DIR/docker-compose.yaml" password dir
    local sites=() url_clients=()

    _redis_shared_define
    password=$(redis_shared_password)

    for dir in "$STACKS_DIR"/*/; do
        dir="${dir%/}"
        [ -f "$dir/docker-compose.yaml" ] || continue
        if [ "$(cat "$dir/.redis-host" 2>/dev/null)" = "host-gateway" ]; then
            [ "$(sudo cat "$dir/.redis-pass" 2>/dev/null)" = "$password" ] || sites+=("$dir")
        elif sudo grep -q 'redis://host-gateway:6379' "$dir/docker-compose.yaml"; then
            url_clients+=("$dir")
        fi
    done

    for dir in "${sites[@]}"; do _redis_shared_configure_site "$dir" "$password"; done
    sudo docker compose -f "$compose" up -d
    for dir in "${sites[@]}"; do _redis_shared_reload_site "$dir" "$password"; done
    for dir in "${url_clients[@]}"; do _redis_shared_url_client "$dir" "$password"; done
    sudo docker compose -f "$compose" up -d --wait
}
