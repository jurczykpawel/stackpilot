#!/bin/bash
# WordPress shared cache: published on the Docker bridge address, password for every client.
set -e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"
ORIGINAL_PATH="$PATH"
REAL_SED=$(command -v sed)

setup() {
    TEST_TMPDIR=$(mktemp -d)
    mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/stacks" "$TEST_TMPDIR/toolbox/system" "$TEST_TMPDIR/toolbox/lib"
    echo 'echo "stack update: $APP_NAME"' > "$TEST_TMPDIR/toolbox/system/update-stack.sh"
    echo 'detect_redis() { REDIS_HOST="${DETECTED_REDIS:-$2}"; }' > "$TEST_TMPDIR/toolbox/lib/redis-detect.sh"
    echo 'wait_for_healthy() { :; }' > "$TEST_TMPDIR/toolbox/lib/health-check.sh"
    cat > "$TEST_TMPDIR/bin/docker" <<'MOCK'
#!/bin/bash
printf '%s|%s\n' "${PWD##*/}" "$*" >> "$DOCKER_CALLS"
case "$*" in
    *'redis-shared/docker-compose.yaml up -d'*) [ -z "${FAIL_REDIS_START:-}" ] || exit 1 ;;
    'run --rm --add-host h:host-gateway redis:alpine getent hosts h')
        [ -z "${HOST_GATEWAY-172.17.0.1}" ] || printf '%s  h  h\n' fd00::1 "${HOST_GATEWAY-172.17.0.1}" ;;
    'compose ps --status running -q'*) printf '%s' "${RUNNING-cid}" ;;
    'compose ps -q wordpress') echo cid ;;
    'compose run '*)
        # Run the container script against the stack's fake web root
        script="${@: -1}"
        sh -c "${script//\/var\/www\/html/$PWD/html}" ;;
    'exec -i cid tee '*) cat > "$PERF_CAPTURE" ;;
    'exec cid test -f /usr/local/bin/wp') exit 1 ;;
esac
exit 0
MOCK
    cat > "$TEST_TMPDIR/bin/sed" <<MOCK
#!/bin/bash
[ "\$1" = -i ] && exit 0
exec "$REAL_SED" "\$@"
MOCK
    printf '#!/bin/bash\nexec "$@"\n' > "$TEST_TMPDIR/bin/sudo"
    printf '#!/bin/bash\necho "Mem: 2048 100 1900"\n' > "$TEST_TMPDIR/bin/free"
    printf '#!/bin/bash\necho "$*" >> "$CHOWN_CALLS"\n' > "$TEST_TMPDIR/bin/chown"
    printf '#!/bin/bash\n[ "$1" = - ] && cat >/dev/null\nexit 0\n' > "$TEST_TMPDIR/bin/crontab"
    printf '#!/bin/bash\necho 0\n' > "$TEST_TMPDIR/bin/mysql"
    local name
    for name in curl sleep ip; do printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/bin/$name"; done
    chmod +x "$TEST_TMPDIR/bin/"*
    export PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
    export STACKS_DIR="$TEST_TMPDIR/stacks" STACKPILOT_DIR="$TEST_TMPDIR/toolbox"
    export DOCKER_CALLS="$TEST_TMPDIR/docker.calls" CHOWN_CALLS="$TEST_TMPDIR/chown.calls"
    export PERF_CAPTURE="$TEST_TMPDIR/perf.php"
    export DOMAIN=blog.example.com DB_HOST=db DB_USER=wp DB_PASS=wp-db-pass YES_MODE=true
    SHARED="$STACKS_DIR/redis-shared"
}
teardown() {
    PATH="$ORIGINAL_PATH"
    unset BUNDLED_DB_TYPE STACKS_DIR STACKPILOT_DIR DOCKER_CALLS CHOWN_CALLS PERF_CAPTURE WP_REDIS REDIS_PASS POSTIZ_REDIS DOMAIN DB_HOST DB_USER DB_PASS YES_MODE HOST_GATEWAY RUNNING DETECTED_REDIS
    rm -rf "$TEST_TMPDIR"
}

install_wordpress() { bash "$REPO_ROOT/apps/wordpress/install.sh" > "$TEST_TMPDIR/output" 2>&1; }
update_wordpress() { bash "$REPO_ROOT/apps/wordpress/update.sh" > "$TEST_TMPDIR/output" 2>&1; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
shared_password() { "$REAL_SED" -n 's/^REDIS_PASSWORD=//p' "$SHARED/.env" 2>/dev/null; }
calls() { cat "$DOCKER_CALLS" 2>/dev/null || true; }

wordpress_client() {
    local dir="$STACKS_DIR/$1"
    mkdir -p "$dir/html"
    echo 'services: {wordpress: {build: .}}' > "$dir/docker-compose.yaml"
    echo "$2" > "$dir/.redis-host"
    cat > "$dir/html/wp-config-performance.php" <<'PHP'
<?php
defined('WP_REDIS_HOST')   || define('WP_REDIS_HOST', 'host-gateway');
defined('WP_REDIS_PORT')   || define('WP_REDIS_PORT', 6379);
defined('WP_CACHE')        || define('WP_CACHE', true);
PHP
}
existing_installation() {
    mkdir -p "$SHARED" "$STACKS_DIR/postiz"
    printf 'services:\n  redis:\n    image: redis:alpine\n    ports:\n      - "6379:6379"\n' > "$SHARED/docker-compose.yaml"
    wordpress_client wordpress-blog host-gateway
    wordpress_client wordpress-old redis
    printf '      - REDIS_URL=redis://host-gateway:6379\n' > "$STACKS_DIR/postiz/docker-compose.yaml"
}

test_data_service_ports_name_a_host_address() {
    local found
    found=$(grep -HnE '^[[:space:]]*-[[:space:]]*"?(\$\{?[A-Za-z_]+\}?|[0-9]+):(6379|5432|3306|27017|11211|5672|9200)"?[[:space:]]*$' \
        "$REPO_ROOT"/apps/*/*.sh || true)
    assert_eq '' "$found" 'data service ports carry a host address'
}
test_bundled_mysql_is_part_of_the_stack() {
    BUNDLED_DB_TYPE=mysql install_wordpress
    local compose
    compose=$(cat "$STACKS_DIR/wordpress-blog/docker-compose.yaml")
    assert_contains "$compose" "image: mysql:8.0"
    assert_contains "$compose" "db-data:/var/lib/mysql"
    assert_contains "$compose" "MYSQL_PASSWORD: wp-db-pass"
    assert_contains "$compose" "  db-data:"
}
test_external_database_adds_no_db_service() {
    install_wordpress
    assert_true test -s "$STACKS_DIR/wordpress-blog/docker-compose.yaml"
    assert_not_contains "$(cat "$STACKS_DIR/wordpress-blog/docker-compose.yaml")" "image: mysql"
}
test_fresh_install_publishes_on_bridge_address_with_password() {
    install_wordpress
    local compose password
    compose=$(cat "$SHARED/docker-compose.yaml")
    password=$(shared_password)
    assert_contains "$compose" '"172.17.0.1:6379:6379"'
    assert_contains "$compose" '--requirepass ${REDIS_PASSWORD}'
    assert_contains "$compose" 'REDISCLI_AUTH=${REDIS_PASSWORD}'
    assert_true test "${#password}" -ge 32
    assert_not_contains "$compose" "${password:-missing}" 'compose file holds no secret'
    assert_eq 600 "$(file_mode "$SHARED/.env")"
    assert_contains "$(calls)" "compose -f $SHARED/docker-compose.yaml up -d --wait"
}
test_fresh_install_hands_password_to_wordpress() {
    install_wordpress
    local stack="$STACKS_DIR/wordpress-blog" password
    password=$(shared_password)
    assert_eq "${password:-missing}" "$(cat "$stack/.redis-pass" 2>/dev/null)"
    assert_eq 600 "$(file_mode "$stack/.redis-pass")"
    assert_contains "$(cat "$CHOWN_CALLS")" "$(id -u):$(id -g) $stack/.redis-pass" 'wp-init.sh can read it'
    assert_contains "$(cat "$PERF_CAPTURE")" "define('WP_REDIS_PASSWORD', '${password:-missing}')"
    assert_not_contains "$(cat "$TEST_TMPDIR/output")" "${password:-missing}"
    assert_contains "$(calls)" 'wordpress-blog|compose kill -s USR2 wordpress' 'PHP-FPM reloads the config'
}
test_password_survives_reinstall_and_next_site() {
    install_wordpress
    local first
    first=$(shared_password)
    install_wordpress
    DOMAIN=shop.example.com install_wordpress
    assert_eq "${first:-missing}" "$(shared_password)"
    assert_eq "${first:-missing}" "$(cat "$STACKS_DIR/wordpress-shop/.redis-pass" 2>/dev/null)"
}
test_detected_shared_cache_is_used_with_its_password() {
    install_wordpress
    export DETECTED_REDIS=host-gateway
    DOMAIN=shop.example.com install_wordpress
    local password
    password=$(shared_password)
    assert_eq "${password:-missing}" "$(cat "$STACKS_DIR/wordpress-shop/.redis-pass" 2>/dev/null)"
}
test_own_external_redis_is_left_alone() {
    export DETECTED_REDIS=host-gateway
    REDIS_PASS=own-secret install_wordpress
    assert_false test -e "$SHARED"
    assert_eq own-secret "$(cat "$STACKS_DIR/wordpress-blog/.redis-pass")"
}
test_explicit_external_redis_wins_over_the_shared_one() {
    existing_installation
    export DETECTED_REDIS=host-gateway
    WP_REDIS=external REDIS_PASS=own-secret DOMAIN=shop.example.com install_wordpress
    assert_eq own-secret "$(cat "$STACKS_DIR/wordpress-shop/.redis-pass")"
    assert_contains "$(cat "$PERF_CAPTURE")" "define('WP_REDIS_PASSWORD', 'own-secret')"
    assert_not_contains "$(calls)" 'redis-shared'
}
test_explicit_external_redis_survives_a_later_update() {
    existing_installation
    export DETECTED_REDIS=host-gateway
    WP_REDIS=external REDIS_PASS=own-secret DOMAIN=shop.example.com install_wordpress
    : > "$DOCKER_CALLS"
    update_wordpress
    assert_eq own-secret "$(cat "$STACKS_DIR/wordpress-shop/.redis-pass")"
    assert_not_contains "$(calls)" 'wordpress-shop|'
}
test_reinstall_without_external_returns_to_the_shared_cache() {
    existing_installation
    export DETECTED_REDIS=host-gateway
    WP_REDIS=external REDIS_PASS=own-secret DOMAIN=shop.example.com install_wordpress
    DOMAIN=shop.example.com install_wordpress
    assert_eq "$(shared_password)" "$(cat "$STACKS_DIR/wordpress-shop/.redis-pass")"
    assert_false test -e "$STACKS_DIR/wordpress-shop/.redis-external"
}
test_passwordless_external_redis_drops_the_shared_password() {
    install_wordpress
    export DETECTED_REDIS=host-gateway
    WP_REDIS=external install_wordpress
    assert_false test -e "$STACKS_DIR/wordpress-blog/.redis-pass"
    assert_not_contains "$(cat "$PERF_CAPTURE")" 'WP_REDIS_PASSWORD'
}
test_external_without_a_redis_on_the_host_uses_the_shared_one() {
    existing_installation
    WP_REDIS=external DOMAIN=shop.example.com install_wordpress
    assert_eq "$(shared_password)" "$(cat "$STACKS_DIR/wordpress-shop/.redis-pass")"
    assert_false test -e "$STACKS_DIR/wordpress-shop/.redis-external"
}
test_update_migrates_existing_installation() {
    existing_installation
    update_wordpress
    local password perf
    password=$(shared_password)
    assert_contains "$(cat "$SHARED/docker-compose.yaml")" '"172.17.0.1:6379:6379"'
    assert_not_contains "$(cat "$SHARED/docker-compose.yaml")" '- "6379:6379"'
    assert_true test -f "$SHARED/docker-compose.yaml.bak"
    perf=$(cat "$STACKS_DIR/wordpress-blog/html/wp-config-performance.php")
    assert_contains "$perf" "define('WP_REDIS_PASSWORD', '${password:-missing}')"
    assert_contains "$perf" "define('WP_CACHE', true)"
    assert_eq "${password:-missing}" "$(cat "$STACKS_DIR/wordpress-blog/.redis-pass" 2>/dev/null)"
    assert_contains "$(calls)" 'wordpress-blog|compose kill -s USR2 wordpress'
    assert_contains "$(cat "$STACKS_DIR/postiz/docker-compose.yaml")" "REDIS_URL=redis://:${password:-missing}@host-gateway:6379"
    assert_contains "$(calls)" 'postiz|compose up -d'
    assert_false test -e "$STACKS_DIR/wordpress-old/.redis-pass"
    assert_not_contains "$(calls)" 'wordpress-old|'
    assert_not_contains "$(cat "$TEST_TMPDIR/output")" "${password:-missing}"
}
test_sites_get_settings_before_redis_restarts_and_reload_right_after() {
    existing_installation
    update_wordpress
    local write start reload
    write=$(grep -nF 'wordpress-blog|compose run ' "$DOCKER_CALLS" | head -1 | cut -d: -f1)
    start=$(grep -n 'redis-shared/docker-compose.yaml up -d$' "$DOCKER_CALLS" | head -1 | cut -d: -f1)
    reload=$(grep -nF 'wordpress-blog|compose kill -s USR2' "$DOCKER_CALLS" | head -1 | cut -d: -f1)
    assert_true test "${write:-0}" -gt 0
    assert_true test "${write:-0}" -lt "${start:-0}"
    assert_true test "${start:-0}" -lt "${reload:-0}"
}
test_failed_redis_start_is_retried_for_every_site() {
    existing_installation
    local rc=0
    FAIL_REDIS_START=1 update_wordpress || rc=$?
    assert_not_eq 0 "$rc"
    assert_false test -e "$STACKS_DIR/wordpress-blog/.redis-pass"
    update_wordpress
    assert_contains "$(calls)" 'wordpress-blog|compose kill -s USR2 wordpress'
    assert_eq 1 "$(grep -c WP_REDIS_PASSWORD\'\, "$STACKS_DIR/wordpress-blog/html/wp-config-performance.php")"
}
test_second_update_changes_nothing_for_clients() {
    existing_installation
    mkdir -p "$STACKS_DIR/wordpress"
    update_wordpress
    : > "$DOCKER_CALLS"
    update_wordpress
    assert_eq 1 "$(grep -c WP_REDIS_PASSWORD\'\, "$STACKS_DIR/wordpress-blog/html/wp-config-performance.php")"
    assert_not_contains "$(calls)" 'USR2'
    assert_not_contains "$(calls)" 'postiz|'
    assert_contains "$(cat "$TEST_TMPDIR/output")" 'stack update: wordpress'
}
test_update_without_default_stack_succeeds() {
    existing_installation
    local rc=0
    update_wordpress || rc=$?
    assert_eq 0 "$rc"
    assert_not_contains "$(cat "$TEST_TMPDIR/output")" 'stack update:'
}
test_update_without_shared_cache_creates_none() {
    mkdir -p "$STACKS_DIR/wordpress"
    update_wordpress
    assert_false test -e "$SHARED"
    assert_contains "$(cat "$TEST_TMPDIR/output")" 'stack update: wordpress'
}
test_url_client_with_an_old_password_gets_the_current_one() {
    existing_installation
    printf '      - REDIS_URL=redis://:old-secret@host-gateway:6379\n' > "$STACKS_DIR/postiz/docker-compose.yaml"
    update_wordpress
    local password
    password=$(shared_password)
    assert_eq "      - REDIS_URL=redis://:${password:-missing}@host-gateway:6379" "$(cat "$STACKS_DIR/postiz/docker-compose.yaml")"
    assert_contains "$(calls)" 'postiz|compose up -d'
}
test_url_client_of_another_redis_is_left_alone() {
    existing_installation
    local other='      - REDIS_URL=redis://:own-secret@cache.example.com:6379'
    echo "$other" > "$STACKS_DIR/postiz/docker-compose.yaml"
    update_wordpress
    assert_eq "$other" "$(cat "$STACKS_DIR/postiz/docker-compose.yaml")"
    assert_not_contains "$(calls)" 'postiz|'
}
test_site_password_is_not_a_command_argument() {
    existing_installation
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" >> "%s"\nexec "%s" "$@"\n' "$TEST_TMPDIR/awk.args" "$(PATH="$ORIGINAL_PATH" command -v awk)" > "$TEST_TMPDIR/bin/awk"
    chmod +x "$TEST_TMPDIR/bin/awk"
    update_wordpress
    local password
    password=$(shared_password)
    assert_contains "$(cat "$STACKS_DIR/wordpress-blog/html/wp-config-performance.php")" "${password:-missing}"
    assert_contains "$(cat "$TEST_TMPDIR/awk.args")" 'WP_REDIS_PORT' 'the config rewrite ran through the recorder'
    assert_not_contains "$(cat "$TEST_TMPDIR/awk.args")" "${password:-missing}"
}
test_stopped_clients_stay_stopped() {
    existing_installation
    RUNNING='' update_wordpress
    assert_contains "$(cat "$STACKS_DIR/wordpress-blog/html/wp-config-performance.php")" 'WP_REDIS_PASSWORD'
    assert_not_contains "$(calls)" 'USR2'
    assert_not_contains "$(calls)" 'postiz|compose up -d'
}
test_address_is_the_one_docker_gives_containers() {
    HOST_GATEWAY=10.200.0.1 install_wordpress
    assert_contains "$(cat "$SHARED/docker-compose.yaml")" '"10.200.0.1:6379:6379"'
}
test_update_follows_a_changed_address() {
    existing_installation
    update_wordpress
    local password
    password=$(shared_password)
    : > "$DOCKER_CALLS"
    HOST_GATEWAY=10.200.0.1 update_wordpress
    assert_contains "$(cat "$SHARED/docker-compose.yaml")" '"10.200.0.1:6379:6379"'
    assert_contains "$(cat "$SHARED/docker-compose.yaml.bak")" '"172.17.0.1:6379:6379"'
    assert_eq "${password:-missing}" "$(shared_password)"
    assert_contains "$(calls)" "compose -f $SHARED/docker-compose.yaml up -d --wait"
    assert_not_contains "$(calls)" 'compose run ' 'clients keep their settings'
}
test_unchanged_address_keeps_the_definition() {
    existing_installation
    update_wordpress
    echo '# local note' >> "$SHARED/docker-compose.yaml"
    update_wordpress
    assert_contains "$(cat "$SHARED/docker-compose.yaml")" '# local note'
}
test_unknown_bridge_address_changes_nothing() {
    existing_installation
    local before rc=0
    before=$(cat "$SHARED/docker-compose.yaml")
    HOST_GATEWAY='' update_wordpress || rc=$?
    assert_not_eq 0 "$rc"
    assert_contains "$(cat "$TEST_TMPDIR/output")" 'bridge address'
    assert_eq "$before" "$(cat "$SHARED/docker-compose.yaml")"
    assert_not_contains "$(calls)" 'up -d'
}
# Real Redis detection on a host where something listens on 6379
install_postiz() {
    echo "source '$REPO_ROOT/lib/redis-detect.sh'" > "$STACKPILOT_DIR/lib/redis-detect.sh"
    printf '#!/bin/bash\necho "LISTEN 0 511 172.17.0.1:6379 0.0.0.0:*"\n' > "$TEST_TMPDIR/bin/ss"
    chmod +x "$TEST_TMPDIR/bin/ss"
    mkdir -p "$SHARED"
    echo 'REDIS_PASSWORD=abc123' > "$SHARED/.env"
    bash "$REPO_ROOT/apps/postiz/install.sh" > "$TEST_TMPDIR/output" 2>&1 || true
    POSTIZ_COMPOSE=$(cat "$STACKS_DIR/postiz/docker-compose.yaml" 2>/dev/null)
}
test_postiz_brings_its_own_redis_by_default() {
    install_postiz
    assert_contains "$POSTIZ_COMPOSE" 'REDIS_URL=redis://postiz-redis:6379'
    assert_contains "$POSTIZ_COMPOSE" 'image: redis:7.2-alpine'
    assert_contains "$POSTIZ_COMPOSE" '--maxmemory-policy noeviction'
    assert_not_contains "$POSTIZ_COMPOSE" 'abc123'
}
test_postiz_install_uses_shared_cache_password() {
    POSTIZ_REDIS=external install_postiz
    assert_contains "$POSTIZ_COMPOSE" 'REDIS_URL=redis://:abc123@host-gateway:6379'
    assert_not_contains "$POSTIZ_COMPOSE" 'image: redis:7.2-alpine'
}
test_remote_install_passes_redis_choice_to_the_server() {
    printf '#!/bin/bash\necho "$*" >> "%s"\n[ "$1" = -G ] && echo "hostname 192.0.2.1"\nexit 0\n' "$TEST_TMPDIR/ssh.calls" > "$TEST_TMPDIR/bin/ssh"
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/bin/scp"
    chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/scp"
    HOME="$TEST_TMPDIR" WP_DB_MODE=sqlite WP_REDIS=external REDIS_PASS='own secret' \
        bash "$REPO_ROOT/local/deploy.sh" wordpress --ssh=test-host --domain-type=local --yes > "$TEST_TMPDIR/output" 2>&1 || true
    local command
    command=$(grep "bash '/tmp/sp-deploy-" "$TEST_TMPDIR/ssh.calls")
    assert_contains "$command" "WP_REDIS='external'"
    assert_contains "$command" 'REDIS_PASS=own\ secret'
}
test_remote_install_passes_postiz_redis_choice_to_the_server() {
    printf '#!/bin/bash\necho "$*" >> "%s"\n[ "$1" = -G ] && echo "hostname 192.0.2.1"\nexit 0\n' "$TEST_TMPDIR/ssh.calls" > "$TEST_TMPDIR/bin/ssh"
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/bin/scp"
    chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/scp"
    HOME="$TEST_TMPDIR" POSTIZ_REDIS=external \
        bash "$REPO_ROOT/local/deploy.sh" postiz --ssh=test-host --db-source=bundled --domain-type=local --yes > "$TEST_TMPDIR/output" 2>&1 || true
    assert_contains "$(grep "bash '/tmp/sp-deploy-" "$TEST_TMPDIR/ssh.calls")" "POSTIZ_REDIS='external'"
}
test_remote_update_ships_cache_helper() {
    printf '#!/bin/bash\necho "$*" >> "%s"\n[ "$1" = -G ] && echo "hostname 192.0.2.1"\nexit 0\n' "$TEST_TMPDIR/ssh.calls" > "$TEST_TMPDIR/bin/ssh"
    printf '#!/bin/bash\necho "$*" >> "%s"\n' "$TEST_TMPDIR/scp.calls" > "$TEST_TMPDIR/bin/scp"
    chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/scp"
    HOME="$TEST_TMPDIR" bash "$REPO_ROOT/local/deploy.sh" wordpress --ssh=test-host --update --yes > "$TEST_TMPDIR/output" 2>&1 || true
    assert_contains "$(cat "$TEST_TMPDIR/scp.calls")" 'apps/wordpress/redis-shared.sh test-host:/tmp/sp-wp-redis-'
    assert_contains "$(cat "$TEST_TMPDIR/ssh.calls")" "WP_REDIS_SHARED_LIB='/tmp/sp-wp-redis-"
}

run_tests "$0"
