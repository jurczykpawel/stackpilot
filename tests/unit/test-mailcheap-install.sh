#!/bin/bash
set -e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
# shellcheck source=tests/unit/test-runner.sh
source "$TESTS_DIR/test-runner.sh"
ORIGINAL_PATH="$PATH"
REAL_DOCKER=$(command -v docker || true)
REAL_TEE=$(command -v tee)
export REAL_TEE
setup() {
    TEST_TMPDIR=$(mktemp -d)
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/bash\n"$@"\n' > "$TEST_TMPDIR/bin/sudo"
    cat > "$TEST_TMPDIR/bin/docker" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [ "$1 $2" = 'load -i' ]; then
    exit "${LOAD_EXIT:-0}"
fi
[ "${IMAGE_MISSING:-}" != true ]
MOCK
    cat > "$TEST_TMPDIR/bin/curl" <<'MOCK'
#!/bin/bash
[ "${HEALTH_FAIL:-}" != true ] || exit 1
case "$*" in
    */signin*) [ "${SIGNIN_FAIL:-}" != true ] || exit 1; printf '%s' "${SIGNIN_BODY-Sign in to MailCheap}" ;;
esac
MOCK
    cat > "$TEST_TMPDIR/bin/tee" <<'MOCK'
#!/bin/bash
if [ "${CHECK_ENV_MODE:-}" = true ] && [ "$1" = .env ]; then
    mode=$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env 2>/dev/null)
    [ "$mode" = 600 ] || { echo '.env must exist with mode 600 before writing' >&2; exit 1; }
fi
exec "$REAL_TEE" "$@"
MOCK
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/bin/sleep"
    chmod +x "$TEST_TMPDIR/bin/"*
    export PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH" DOCKER_LOG="$TEST_TMPDIR/docker.log"
}
teardown() { PATH="$ORIGINAL_PATH"; rm -rf "$TEST_TMPDIR"; }
run_install() { STACK_DIR="$TEST_TMPDIR/stack" PORT=8142 DOMAIN="${TEST_DOMAIN-mail.example.com}" DOMAIN_TYPE="${TEST_DOMAIN_TYPE:-caddy}" bash "$REPO_ROOT/apps/mailcheap/install.sh"; }
test_generates_distinct_stable_secrets() {
    run_install >/dev/null || return
    local before auth suppression
    before=$(cat "$TEST_TMPDIR/stack/.env")
    auth=$(sed -n 's/^BETTER_AUTH_SECRET=//p' "$TEST_TMPDIR/stack/.env")
    suppression=$(sed -n 's/^SUPPRESSION_HASH_KEY=//p' "$TEST_TMPDIR/stack/.env")
    assert_true test "${#auth}" -ge 32
    assert_true test "${#suppression}" -ge 32
    assert_not_eq "$auth" "$suppression"
    printf '\nADMIN_EMAILS=owner@example.com\n' >> "$TEST_TMPDIR/stack/.env"
    run_install >/dev/null || return
    assert_contains "$(cat "$TEST_TMPDIR/stack/.env")" "$before"
    assert_contains "$(cat "$TEST_TMPDIR/stack/.env")" 'ADMIN_EMAILS=owner@example.com'
    assert_eq 600 "$(stat -c '%a' "$TEST_TMPDIR/stack/.env" 2>/dev/null || stat -f '%Lp' "$TEST_TMPDIR/stack/.env" 2>/dev/null)"
}
test_binds_only_web_and_has_authenticated_persistent_mongo() {
    run_install >/dev/null || return
    local compose
    compose=$(cat "$TEST_TMPDIR/stack/docker-compose.yaml")
    assert_contains "$compose" '127.0.0.1:8142:3000'
    assert_contains "$compose" 'mongo:7.0.45'
    assert_contains "$compose" 'mongo-data:/data/db'
    assert_contains "$compose" 'MONGO_INITDB_ROOT_PASSWORD:'
    assert_contains "$compose" 'authSource=admin'
    assert_eq 1 "$(grep -c 'ports:' "$TEST_TMPDIR/stack/docker-compose.yaml")"
    assert_contains "$compose" 'APP_URL: "https://mail.example.com"'
    assert_contains "$(cat "$TEST_TMPDIR/docker.log")" 'up -d --wait'
}
test_cytrus_binds_all_interfaces() {
    TEST_DOMAIN_TYPE=cytrus run_install >/dev/null || return
    assert_contains "$(cat "$TEST_TMPDIR/stack/docker-compose.yaml")" '"8142:3000"'
}
test_local_url_uses_forwarded_port() {
    TEST_DOMAIN='' run_install >/dev/null || return
    assert_contains "$(cat "$TEST_TMPDIR/stack/docker-compose.yaml")" 'APP_URL: "http://localhost:8142"'
}
test_generated_compose_is_accepted_by_docker() {
    if [ -z "$REAL_DOCKER" ] || ! "$REAL_DOCKER" compose version >/dev/null 2>&1; then
        skip_test "Docker Compose not installed"
        return
    fi
    run_install >/dev/null || return
    assert_true "$REAL_DOCKER" compose -f "$TEST_TMPDIR/stack/docker-compose.yaml" config --quiet
}
test_partial_configuration_is_preserved_and_fails_before_start() {
    mkdir -p "$TEST_TMPDIR/stack"
    printf 'BETTER_AUTH_SECRET=retain-this-existing-key-retain-this-existing-key\n' > "$TEST_TMPDIR/stack/.env"
    local before output rc=0
    before=$(cat "$TEST_TMPDIR/stack/.env")
    output=$(run_install 2>&1) || rc=$?
    assert_eq 1 "$rc"
    assert_contains "$output" 'MONGO_ROOT_PASSWORD'
    assert_eq "$before" "$(cat "$TEST_TMPDIR/stack/.env")"
    assert_not_contains "$(cat "$TEST_TMPDIR/docker.log")" 'up -d'
}
test_empty_and_short_secrets_fail_before_start() {
    run_install >/dev/null || return
    sed '/^SUPPRESSION_HASH_KEY=/s/=.*/=short/' "$TEST_TMPDIR/stack/.env" > "$TEST_TMPDIR/changed-env"
    mv "$TEST_TMPDIR/changed-env" "$TEST_TMPDIR/stack/.env"
    : > "$TEST_TMPDIR/docker.log"
    local output rc=0
    output=$(run_install 2>&1) || rc=$?
    assert_eq 1 "$rc"
    assert_contains "$output" 'SUPPRESSION_HASH_KEY'
    assert_not_contains "$(cat "$TEST_TMPDIR/docker.log")" 'up -d'
}
test_env_is_private_before_first_write() {
    CHECK_ENV_MODE=true run_install >/dev/null || return
    assert_true test -s "$TEST_TMPDIR/stack/.env"
}
test_build_file_is_loaded_before_image_inspection() {
    : > "$TEST_TMPDIR/image.tar"
    BUILD_FILE="$TEST_TMPDIR/image.tar" run_install >/dev/null || return
    assert_eq "load -i $TEST_TMPDIR/image.tar" "$(head -1 "$TEST_TMPDIR/docker.log")"
    assert_contains "$(sed -n '2p' "$TEST_TMPDIR/docker.log")" 'image inspect stackpilot/mailcheap:'
}
test_missing_build_file_stops_before_docker() {
    local output rc=0
    output=$(BUILD_FILE="$TEST_TMPDIR/missing-image.tar" run_install 2>&1) || rc=$?
    assert_eq 1 "$rc"
    assert_contains "$output" 'BUILD_FILE'
    assert_false test -f "$TEST_TMPDIR/docker.log"
}
test_failed_image_load_stops_before_inspection() {
    : > "$TEST_TMPDIR/image.tar"
    local rc=0
    BUILD_FILE="$TEST_TMPDIR/image.tar" LOAD_EXIT=1 run_install >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc"
    assert_not_contains "$(cat "$TEST_TMPDIR/docker.log")" 'image inspect'
}
test_success_persists_selected_host_port() {
    run_install >/dev/null || return
    assert_eq 8142 "$(cat "$TEST_TMPDIR/stack/.stackpilot-port")"
}
test_missing_image_fails_with_preparation_command() {
    local output rc=0
    output=$(IMAGE_MISSING=true run_install 2>&1) || rc=$?
    assert_eq 1 "$rc"
    assert_contains "$output" 'apps/mailcheap/build.sh'
    assert_false test -f "$TEST_TMPDIR/stack/docker-compose.yaml"
}
test_configuration_health_without_signin_does_not_report_success() {
    local output rc=0
    output=$(SIGNIN_FAIL=true run_install 2>&1) || rc=$?
    assert_eq 1 "$rc"
    assert_not_contains "$output" 'MailCheap installed'
    assert_false test -f "$TEST_TMPDIR/stack/.stackpilot-port"
}
test_signin_response_must_contain_the_login_form() {
    local rc=0
    SIGNIN_BODY='An error occurred' run_install >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc"
}
test_container_readiness_uses_signin_page() {
    run_install >/dev/null || return
    assert_contains "$(cat "$TEST_TMPDIR/stack/docker-compose.yaml")" "fetch('http://127.0.0.1:3000/signin')"
    assert_contains "$(cat "$TEST_TMPDIR/stack/docker-compose.yaml")" "includes('Sign in to MailCheap')"
}
test_unhealthy_service_does_not_report_success() {
    local output rc=0
    output=$(HEALTH_FAIL=true run_install 2>&1) || rc=$?
    assert_eq 1 "$rc"
    assert_not_contains "$output" 'MailCheap installed'
}
run_tests "$0"
