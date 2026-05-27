#!/bin/bash

# Unit tests for apps/sgtm/install.sh
# Tests validation logic (CONTAINER_CONFIG check) and compose file generation.
# Docker/sudo calls are mocked; STACK_DIR is overridden via env so no server is needed.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/apps/sgtm/install.sh"

source "$TESTS_DIR/test-runner.sh"

# =============================================================================
# Helpers
# =============================================================================

MOCK_BIN=""

setup() {
    TEST_TMPDIR=$(mktemp -d)

    # Create mock bin directory
    MOCK_BIN="$TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"

    # Mock sudo: strip 'sudo' and run as current user
    cat > "$MOCK_BIN/sudo" << 'EOF'
#!/bin/bash
"$@"
EOF
    chmod +x "$MOCK_BIN/sudo"

    # Mock docker: succeed silently (compose up -d / ps)
    cat > "$MOCK_BIN/docker" << 'EOF'
#!/bin/bash
if [ "$1" = "compose" ] && [ "$2" = "ps" ]; then
    printf '{"Name":"sgtm","State":"running"}\n'
    exit 0
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/docker"

    # Mock sleep: no-op for fast tests
    cat > "$MOCK_BIN/sleep" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_BIN/sleep"

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    unset CONTAINER_CONFIG DOMAIN PORT STACK_DIR
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# Run install.sh with STACK_DIR redirected to TEST_TMPDIR so no /opt/stacks writes occur.
run_install() {
    local extra_env="${1:-}"
    local stack_dir="$TEST_TMPDIR/stacks/sgtm"
    mkdir -p "$stack_dir"
    eval "$extra_env STACK_DIR='$stack_dir' bash '$INSTALL_SH'" 2>&1
}

compose_file() {
    echo "$TEST_TMPDIR/stacks/sgtm/docker-compose.yaml"
}

# =============================================================================
# Validation tests
# =============================================================================

test_fails_without_container_config() {
    set +e
    output=$(CONTAINER_CONFIG="" bash "$INSTALL_SH" 2>&1)
    rc=$?
    set -e
    assert_eq "1" "$rc" "exits 1 when CONTAINER_CONFIG is missing"
    assert_contains "$output" "CONTAINER_CONFIG" "error message mentions CONTAINER_CONFIG"
    assert_contains "$output" "GTM" "error message references GTM"
}

test_error_shows_example_command() {
    set +e
    output=$(CONTAINER_CONFIG="" bash "$INSTALL_SH" 2>&1)
    set -e
    assert_contains "$output" "deploy.sh sgtm" "error shows deploy.sh sgtm example"
}

test_default_port_is_8084() {
    assert_contains "$(grep 'PORT:-' "$INSTALL_SH")" "8084" "default port is 8084"
}

# =============================================================================
# Compose file generation tests
# =============================================================================

test_succeeds_with_container_config() {
    local fake_config="ZW52LCJodHRwczovL2V4YW1wbGUuY29tIl0="
    set +e
    output=$(run_install "CONTAINER_CONFIG='$fake_config'" 2>&1)
    rc=$?
    set -e
    assert_eq "0" "$rc" "exits 0 when CONTAINER_CONFIG is provided (output: ${output:0:200})"
}

test_compose_file_created() {
    local fake_config="ZW52LCJodHRwczovL2V4YW1wbGUuY29tIl0="
    run_install "CONTAINER_CONFIG='$fake_config'" > /dev/null 2>&1 || true
    local cf
    cf="$(compose_file)"
    assert_eq "exists" "$(test -f "$cf" && echo exists || echo missing)" "docker-compose.yaml created in STACK_DIR"
}

test_compose_contains_sgtm_image() {
    local fake_config="ZW52LCJodHRwczovL2V4YW1wbGUuY29tIl0="
    run_install "CONTAINER_CONFIG='$fake_config'" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" "gtm-cloud-image" "compose uses Google sGTM image"
}

test_compose_embeds_container_config() {
    local fake_config="ZW52LCJodHRwczovL2V4YW1wbGUuY29tIl0="
    run_install "CONTAINER_CONFIG='$fake_config'" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" "$fake_config" "compose embeds CONTAINER_CONFIG value"
}

test_compose_healthcheck_uses_healthz() {
    local fake_config="ZW52LCJodHRwczovL2V4YW1wbGUuY29tIl0="
    run_install "CONTAINER_CONFIG='$fake_config'" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" "/healthz" "healthcheck uses /healthz endpoint"
}

test_compose_memory_limit_256m() {
    local fake_config="ZW52LCJodHRwczovL2V4YW1wbGUuY29tIl0="
    run_install "CONTAINER_CONFIG='$fake_config'" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" "256M" "compose sets 256M memory limit"
}

# =============================================================================
# Success output tests
# =============================================================================

test_success_output_shows_domain() {
    local fake_config="ZW52LCJodHRwczovL2V4YW1wbGUuY29tIl0="
    output=$(run_install "CONTAINER_CONFIG='$fake_config' DOMAIN='gtm.example.com'" 2>&1) || true
    assert_contains "$output" "gtm.example.com" "success output shows configured domain"
}

test_success_warns_when_no_domain() {
    local fake_config="ZW52LCJodHRwczovL2V4YW1wbGUuY29tIl0="
    output=$(run_install "CONTAINER_CONFIG='$fake_config'" 2>&1) || true
    assert_contains "$output" "domain" "warns when no domain is configured"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
