#!/bin/bash
set -e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"
ORIGINAL_PATH="$PATH"
REAL_DOCKER="$(command -v docker || true)"
setup() {
    TEST_TMPDIR=$(mktemp -d)
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/bash\nexec "$@"\n' > "$TEST_TMPDIR/bin/sudo"
    cat > "$TEST_TMPDIR/bin/docker" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$STACK_DIR/docker.calls"
exit "${DOCKER_EXIT:-0}"
MOCK
    cat > "$TEST_TMPDIR/bin/curl" <<'MOCK'
#!/bin/bash
exit "${CURL_EXIT:-0}"
MOCK
    chmod +x "$TEST_TMPDIR/bin/"*
    export PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
    export STACK_DIR="$TEST_TMPDIR/notifuse" PORT=8087 DOMAIN=mail.example.com DOMAIN_TYPE=cloudflare
}
teardown() { PATH="$ORIGINAL_PATH"; rm -rf "$TEST_TMPDIR"; unset STACK_DIR PORT DOMAIN DOMAIN_TYPE DOCKER_EXIT CURL_EXIT; }
install_app() { bash "$REPO_ROOT/apps/notifuse/install.sh" > "$TEST_TMPDIR/output" 2>&1; }
test_new_install_uses_upstream_runtime_contract() {
    install_app || { assert_eq 0 "$?" "installer succeeds"; return; }
    local compose; compose=$(cat "$STACK_DIR/docker-compose.yaml")
    assert_contains "$compose" 'notifuse/notifuse:'
    assert_contains "$compose" 'postgres:17-alpine'
    assert_contains "$compose" 'DB_HOST: postgres'
    assert_contains "$compose" 'DB_SSLMODE: disable'
    assert_contains "$compose" '/healthz'
    assert_contains "$compose" '/var/lib/postgresql/data'
    assert_contains "$compose" 'condition: service_healthy'
    assert_contains "$compose" 'API_ENDPOINT: "https://mail.example.com"'
    assert_contains "$compose" '127.0.0.1:8087:8080'
    assert_eq 8087 "$(cat "$STACK_DIR/.stackpilot-port")"
    assert_not_contains "$compose" ':5432:5432'
    assert_not_contains "$compose" ':587:587'
}
test_secrets_are_generated_and_preserved() {
    install_app || { assert_eq 0 "$?"; return; }
    local first; first=$(cat "$STACK_DIR/.env")
    assert_true grep -Eq '^SECRET_KEY=.{43,}$' "$STACK_DIR/.env"
    assert_true grep -Eq '^DB_PASSWORD=[a-f0-9]{48}$' "$STACK_DIR/.env"
    install_app || { assert_eq 0 "$?"; return; }
    assert_eq "$first" "$(cat "$STACK_DIR/.env")" 'redeploy keeps database and encryption keys'
    local mode; mode=$(stat -c '%a' "$STACK_DIR/.env" 2>/dev/null || stat -f '%Lp' "$STACK_DIR/.env" 2>/dev/null)
    assert_eq 600 "$mode" '.env permissions'
}
test_cytrus_binding() {
    DOMAIN_TYPE=cytrus install_app || { assert_eq 0 "$?"; return; }
    assert_contains "$(cat "$STACK_DIR/docker-compose.yaml")" '"8087:8080"'
}
test_local_url_and_changed_domain() {
    DOMAIN='' install_app || { assert_eq 0 "$?"; return; }
    assert_contains "$(cat "$STACK_DIR/docker-compose.yaml")" 'API_ENDPOINT: "http://localhost:8087"'
    install_app || { assert_eq 0 "$?"; return; }
    assert_contains "$(cat "$STACK_DIR/docker-compose.yaml")" 'API_ENDPOINT: "https://mail.example.com"'
}
test_incomplete_existing_config_is_not_replaced() {
    mkdir -p "$STACK_DIR"
    printf 'SECRET_KEY=keep-this-key\n' > "$STACK_DIR/.env"
    assert_false install_app
    assert_eq 'SECRET_KEY=keep-this-key' "$(cat "$STACK_DIR/.env")"
}
test_failed_start_is_reported() { DOCKER_EXIT=1 assert_false install_app; }
test_failed_host_health_is_reported() { CURL_EXIT=1 assert_false install_app; }
test_real_compose_validation() {
    install_app || { assert_eq 0 "$?"; return; }
    if [ -z "$REAL_DOCKER" ] || ! "$REAL_DOCKER" compose version >/dev/null 2>&1; then skip_test 'docker compose unavailable'; return; fi
    assert_true "$REAL_DOCKER" compose -f "$STACK_DIR/docker-compose.yaml" --env-file "$STACK_DIR/.env" config --quiet
}
run_tests "$0"
