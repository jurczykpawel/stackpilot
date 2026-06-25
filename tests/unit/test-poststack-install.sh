#!/bin/bash

# Unit tests for apps/poststack/install.sh
# Tests auto-generated secrets, .env contents, and compose file generation.
# Docker/sudo/curl/sleep are mocked; STACK_DIR is overridden via env so no server is needed.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/apps/poststack/install.sh"

source "$TESTS_DIR/test-runner.sh"

# =============================================================================
# Helpers
# =============================================================================

MOCK_BIN=""

REAL_DOCKER=""

setup() {
    TEST_TMPDIR=$(mktemp -d)

    # Capture the real docker BEFORE the mock shadows it, so one test can validate
    # the generated compose for real instead of against the mock.
    REAL_DOCKER="$(command -v docker || true)"

    MOCK_BIN="$TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"

    # Mock sudo: strip 'sudo' and run as current user
    cat > "$MOCK_BIN/sudo" << 'EOF'
#!/bin/bash
"$@"
EOF
    chmod +x "$MOCK_BIN/sudo"

    # Mock docker: succeed silently; report running for `compose ps`
    cat > "$MOCK_BIN/docker" << 'EOF'
#!/bin/bash
if [ "$1" = "compose" ] && [ "$2" = "ps" ]; then
    printf '{"Name":"poststack-web","State":"running","Health":"healthy"}\n'
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/docker"

    # Mock curl: always healthy (HTTP 200)
    cat > "$MOCK_BIN/curl" << 'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        -w|*"%{http_code}"*) echo "200" ;;
    esac
done
exit 0
EOF
    chmod +x "$MOCK_BIN/curl"

    # Mock sleep: no-op for fast tests
    cat > "$MOCK_BIN/sleep" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_BIN/sleep"

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    unset DOMAIN DOMAIN_TYPE PORT STACK_DIR IMAGE_TAG
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# Run install.sh with STACK_DIR redirected to TEST_TMPDIR so no /opt/stacks writes occur.
run_install() {
    local extra_env="${1:-}"
    local stack_dir="$TEST_TMPDIR/stacks/poststack"
    eval "$extra_env STACK_DIR='$stack_dir' bash '$INSTALL_SH'" 2>&1
}

compose_file() { echo "$TEST_TMPDIR/stacks/poststack/docker-compose.yaml"; }
env_file()     { echo "$TEST_TMPDIR/stacks/poststack/.env"; }
nginx_file()   { echo "$TEST_TMPDIR/stacks/poststack/nginx.conf"; }

# =============================================================================
# Static contract on the script source
# =============================================================================

test_default_port_is_3000() {
    assert_contains "$(grep 'PORT:-' "$INSTALL_SH")" "3000" "default port is 3000"
}

test_declares_db_bundled() {
    # deploy.sh skips external DB collection when this marker is present
    assert_contains "$(cat "$INSTALL_SH")" "# DB_BUNDLED=true" "declares bundled DB so deploy.sh won't ask for external DB"
}

# =============================================================================
# Compose generation
# =============================================================================

test_compose_created() {
    run_install "DOMAIN='inbox.example.com' DOMAIN_TYPE='cloudflare'" > /dev/null 2>&1 || true
    assert_eq "exists" "$(test -f "$(compose_file)" && echo exists || echo missing)" "docker-compose.yaml created in STACK_DIR"
}

test_compose_has_web_image() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(compose_file)" 2>/dev/null)" "ghcr.io/jurczykpawel/poststack:" "compose pulls the web image from GHCR"
}

test_compose_has_worker_image() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(compose_file)" 2>/dev/null)" "ghcr.io/jurczykpawel/poststack-worker:" "compose pulls the worker image from GHCR"
}

test_compose_has_bundled_postgres() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(compose_file)" 2>/dev/null)" "postgres:16-alpine" "compose bundles PostgreSQL"
}

test_compose_mounts_nginx_conf() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(compose_file)" 2>/dev/null)" "nginx.conf" "compose mounts the generated nginx.conf"
}

test_compose_image_tag_overridable() {
    run_install "DOMAIN='inbox.example.com' IMAGE_TAG='v0.8.3'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(compose_file)" 2>/dev/null)" "poststack:v0.8.3" "IMAGE_TAG pins the image version"
}

test_generated_compose_is_valid_yaml() {
    if [ -z "$REAL_DOCKER" ] || ! "$REAL_DOCKER" compose version >/dev/null 2>&1; then
        skip_test "docker compose not available"
        return 0
    fi
    run_install "DOMAIN='inbox.example.com' DOMAIN_TYPE='cloudflare'" > /dev/null 2>&1 || true
    local dir; dir="$TEST_TMPDIR/stacks/poststack"
    local out; out=$(cd "$dir" && "$REAL_DOCKER" compose config --quiet 2>&1) && local rc=0 || local rc=$?
    assert_eq "0" "$rc" "generated docker-compose.yaml is valid (docker compose config: ${out:0:200})"
}

test_compose_binds_localhost_for_proxy() {
    run_install "DOMAIN='inbox.example.com' DOMAIN_TYPE='cloudflare' PORT='8090'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(compose_file)" 2>/dev/null)" "127.0.0.1:8090:80" "nginx binds to localhost behind a reverse proxy"
}

# =============================================================================
# nginx.conf
# =============================================================================

test_nginx_conf_created() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(nginx_file)" 2>/dev/null)" "proxy_pass http://web:3000" "nginx.conf proxies to the web service"
}

# =============================================================================
# Auto-generated .env (the core ask: set what it can set itself)
# =============================================================================

test_env_created() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    assert_eq "exists" "$(test -f "$(env_file)" && echo exists || echo missing)" ".env created in STACK_DIR"
}

test_env_generates_all_secrets() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    local env; env="$(cat "$(env_file)" 2>/dev/null)"
    assert_contains "$env" "ENCRYPTION_KEY="     "ENCRYPTION_KEY auto-generated"
    assert_contains "$env" "JWT_SECRET="         "JWT_SECRET auto-generated"
    assert_contains "$env" "CRON_SECRET="        "CRON_SECRET auto-generated"
    assert_contains "$env" "ALTCHA_HMAC_KEY="    "ALTCHA_HMAC_KEY auto-generated"
    assert_contains "$env" "POSTGRES_PASSWORD="  "POSTGRES_PASSWORD auto-generated"
}

test_env_has_no_placeholders() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    assert_not_contains "$(cat "$(env_file)" 2>/dev/null)" "change-me" ".env has no leftover change-me placeholders"
}

test_env_secret_is_real() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    local key; key="$(grep '^ENCRYPTION_KEY=' "$(env_file)" 2>/dev/null | cut -d= -f2-)"
    assert_true test "${#key}" -ge 32
}

test_env_app_url_from_domain() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(env_file)" 2>/dev/null)" "APP_URL=https://inbox.example.com" "APP_URL derived from DOMAIN"
}

test_env_node_env_production() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(env_file)" 2>/dev/null)" "NODE_ENV=production" "NODE_ENV set to production"
}

test_trusted_proxy_cloudflare() {
    run_install "DOMAIN='inbox.example.com' DOMAIN_TYPE='cloudflare'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(env_file)" 2>/dev/null)" "TRUSTED_PROXY=cloudflare" "Cloudflare deploy trusts CF-Connecting-IP"
}

test_trusted_proxy_proxy_default() {
    run_install "DOMAIN='inbox.example.com' DOMAIN_TYPE='caddy'" > /dev/null 2>&1 || true
    assert_contains "$(cat "$(env_file)" 2>/dev/null)" "TRUSTED_PROXY=proxy" "Non-Cloudflare deploy trusts the bundled proxy"
}

test_idempotent_preserves_encryption_key() {
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    local first; first="$(grep '^ENCRYPTION_KEY=' "$(env_file)" 2>/dev/null)"
    run_install "DOMAIN='inbox.example.com'" > /dev/null 2>&1 || true
    local second; second="$(grep '^ENCRYPTION_KEY=' "$(env_file)" 2>/dev/null)"
    assert_eq "$first" "$second" "re-running the installer preserves the encryption key (tokens stay decryptable)"
}

# =============================================================================
# Success output
# =============================================================================

test_success_output_shows_domain() {
    output=$(run_install "DOMAIN='inbox.example.com'") || true
    assert_contains "$output" "inbox.example.com" "success output shows the configured domain"
}

test_success_output_mentions_meta_setup() {
    output=$(run_install "DOMAIN='inbox.example.com'") || true
    assert_contains "$output" "Meta" "success output reminds the operator to connect Meta in the UI"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
