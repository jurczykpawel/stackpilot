#!/bin/bash
set -e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"
setup() {
    TEST_TMPDIR=$(mktemp -d)
    ORIGINAL_PATH="$PATH"
    REAL_DOCKER=$(command -v docker || true)
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/bash\n"$@"\n' > "$TEST_TMPDIR/bin/sudo"
    cat > "$TEST_TMPDIR/bin/docker" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_CALLS"
if [ "$*" = 'compose ps --status running -q gateway' ]; then
    printf '%s' "${RUNNING_GATEWAY:-}"
fi
if [[ "$*" == *'nginx -t' ]]; then exit "${NGINX_TEST_EXIT:-0}"; fi
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/"*
    export PATH="$TEST_TMPDIR/bin:$PATH" DOCKER_CALLS="$TEST_TMPDIR/docker-calls"
    export XDG_CONFIG_HOME="$TEST_TMPDIR/config"
    export STACK_DIR="$TEST_TMPDIR/plunk" DOMAIN=mail.example.com DOMAIN_TYPE=cloudflare PORT=3560
    export AWS_SES_REGION=eu-west-1 AWS_SES_ACCESS_KEY_ID=test-key AWS_SES_SECRET_ACCESS_KEY=test-secret
}
teardown() { export PATH="$ORIGINAL_PATH"; unset STACK_DIR DOMAIN DOMAIN_TYPE PORT AWS_SES_REGION AWS_SES_ACCESS_KEY_ID AWS_SES_SECRET_ACCESS_KEY DOCKER_CALLS XDG_CONFIG_HOME RUNNING_GATEWAY NGINX_TEST_EXIT; rm -rf "$TEST_TMPDIR"; }
install() { bash "$REPO_ROOT/apps/plunk/install.sh" > "$TEST_TMPDIR/output" 2>&1; }
test_same_origin_urls_and_proxy() {
    install
    assert_contains "$(cat "$STACK_DIR/.env")" 'API_URI=https://mail.example.com/api'
    assert_contains "$(cat "$STACK_DIR/.env")" 'DASHBOARD_URI=https://mail.example.com'
    assert_contains "$(cat "$STACK_DIR/nginx.conf")" 'proxy_pass http://plunk_api/;'
    assert_contains "$(cat "$STACK_DIR/nginx.conf")" 'proxy_pass http://plunk_web;'
    assert_contains "$(cat "$STACK_DIR/nginx.conf")" 'proxy_pass http://plunk_uploads/uploads/;'
}
test_proxy_and_local_bindings() {
    install
    assert_contains "$(cat "$STACK_DIR/docker-compose.yaml")" '127.0.0.1:3560:80'
    assert_eq 3560 "$(cat "$STACK_DIR/.stackpilot-port")"
    unset DOMAIN
    install
    assert_contains "$(cat "$STACK_DIR/.env")" 'API_URI=http://localhost:3560/api'
}
test_cytrus_binds_public_port() {
    DOMAIN_TYPE=cytrus install
    assert_contains "$(cat "$STACK_DIR/docker-compose.yaml")" '"3560:80"'
    assert_not_contains "$(cat "$STACK_DIR/docker-compose.yaml")" '127.0.0.1:3560:80'
}
test_secrets_survive_reinstall_and_config_is_private() {
    install
    local first
    first=$(grep -E '^(JWT_SECRET|DB_PASSWORD|MINIO_ROOT_PASSWORD)=' "$STACK_DIR/.env")
    install
    assert_eq "$first" "$(grep -E '^(JWT_SECRET|DB_PASSWORD|MINIO_ROOT_PASSWORD)=' "$STACK_DIR/.env")"
    local mode
    mode=$(stat -c '%a' "$STACK_DIR/.env" 2>/dev/null || stat -f '%Lp' "$STACK_DIR/.env" 2>/dev/null)
    assert_eq 600 "$mode"
}
test_missing_ses_stops_before_docker() {
    unset AWS_SES_ACCESS_KEY_ID
    local rc=0
    install || rc=$?
    assert_not_eq 0 "$rc"
    assert_contains "$(cat "$TEST_TMPDIR/output")" 'AWS_SES_ACCESS_KEY_ID'
    assert_true test ! -f "$DOCKER_CALLS"
}
test_persistent_services_and_ready_wait() {
    install
    local compose
    compose=$(cat "$STACK_DIR/docker-compose.yaml")
    assert_contains "$compose" 'ghcr.io/useplunk/plunk:'
    assert_contains "$compose" 'postgres:16-alpine'
    assert_contains "$compose" 'redis:7-alpine'
    assert_contains "$compose" 'postgres_data:'
    assert_contains "$compose" 'minio_data:'
    assert_contains "$(cat "$DOCKER_CALLS")" 'compose up -d --wait'
    assert_not_contains "$compose" ':465'
    assert_not_contains "$compose" ':587'
}
test_compose_configuration() {
    if [ -z "$REAL_DOCKER" ] || ! "$REAL_DOCKER" compose version >/dev/null 2>&1; then
        skip_test 'docker compose unavailable'
        return
    fi
    install
    local rc=0
    (cd "$STACK_DIR" && "$REAL_DOCKER" compose config --quiet) || rc=$?
    assert_eq 0 "$rc" 'generated Compose validates with the real CLI'
}
test_incomplete_existing_configuration_stops_without_rotating_secrets() {
    local key first rc
    for key in DB_PASSWORD JWT_SECRET MINIO_ROOT_PASSWORD; do
        install
        first=$(cat "$STACK_DIR/.env")
        grep -v "^${key}=" "$STACK_DIR/.env" > "$TEST_TMPDIR/partial"
        cp "$TEST_TMPDIR/partial" "$STACK_DIR/.env"
        rm -f "$DOCKER_CALLS"
        rc=0
        install || rc=$?
        assert_not_eq 0 "$rc" "missing $key stops installation"
        assert_eq "$(cat "$TEST_TMPDIR/partial")" "$(cat "$STACK_DIR/.env")" 'existing configuration stays unchanged'
        assert_true test ! -f "$DOCKER_CALLS"
        printf '%s\n' "$first" > "$STACK_DIR/.env"
    done
}
test_empty_existing_secret_stops_before_docker() {
    install
    grep -v '^JWT_SECRET=' "$STACK_DIR/.env" > "$TEST_TMPDIR/partial"
    printf 'JWT_SECRET=\n' >> "$TEST_TMPDIR/partial"
    cp "$TEST_TMPDIR/partial" "$STACK_DIR/.env"
    rm -f "$DOCKER_CALLS"
    local rc=0
    install || rc=$?
    assert_not_eq 0 "$rc"
    assert_true test ! -f "$DOCKER_CALLS"
}
test_new_instances_keep_signup_closed() {
    install
    assert_contains "$(cat "$STACK_DIR/.env")" 'DISABLE_SIGNUPS=true'
}
test_existing_gateway_validates_and_reloads_before_wait() {
    RUNNING_GATEWAY=existing install
    local calls validate reload wait
    calls=$(cat "$DOCKER_CALLS")
    validate=$(printf '%s\n' "$calls" | grep -nF 'compose exec -T gateway nginx -t' | cut -d: -f1)
    reload=$(printf '%s\n' "$calls" | grep -nF 'compose exec -T gateway nginx -s reload' | cut -d: -f1)
    wait=$(printf '%s\n' "$calls" | grep -nF 'compose up -d --wait' | cut -d: -f1)
    assert_true test -n "$validate"
    assert_true test -n "$reload"
    assert_true test "$validate" -lt "$reload"
    assert_true test "$reload" -lt "$wait"
}
test_invalid_existing_gateway_configuration_stops_before_wait() {
    local rc=0
    RUNNING_GATEWAY=existing NGINX_TEST_EXIT=1 install || rc=$?
    assert_not_eq 0 "$rc"
    assert_not_contains "$(cat "$DOCKER_CALLS")" 'compose up -d --wait'
}

run_tests "$0"
