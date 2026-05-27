#!/bin/bash

# Unit tests for apps/watchtower/install.sh
# Tests compose file generation, mode handling, and schedule configuration.
# Docker/sudo calls are mocked; STACK_DIR is overridden via env.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/apps/watchtower/install.sh"

source "$TESTS_DIR/test-runner.sh"

# =============================================================================
# Helpers
# =============================================================================

MOCK_BIN=""

setup() {
    TEST_TMPDIR=$(mktemp -d)

    MOCK_BIN="$TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"

    cat > "$MOCK_BIN/sudo" << 'EOF'
#!/bin/bash
"$@"
EOF
    chmod +x "$MOCK_BIN/sudo"

    cat > "$MOCK_BIN/docker" << 'EOF'
#!/bin/bash
if [ "$1" = "compose" ] && [ "$2" = "ps" ]; then
    printf '{"Name":"watchtower","State":"running"}\n'
    exit 0
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/docker"

    cat > "$MOCK_BIN/sleep" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_BIN/sleep"

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    unset NOTIFICATION_URL REPO_USER REPO_PASS WATCHTOWER_SCHEDULE WATCHTOWER_MODE STACK_DIR TZ
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

run_install() {
    local extra_env="${1:-}"
    local stack_dir="$TEST_TMPDIR/stacks/watchtower"
    mkdir -p "$stack_dir"
    eval "$extra_env STACK_DIR='$stack_dir' bash '$INSTALL_SH'" 2>&1
}

compose_file() {
    echo "$TEST_TMPDIR/stacks/watchtower/docker-compose.yaml"
}

# =============================================================================
# Basic tests
# =============================================================================

test_succeeds_with_no_env_vars() {
    set +e
    output=$(run_install "" 2>&1)
    rc=$?
    set -e
    assert_eq "0" "$rc" "exits 0 with no env vars (output: ${output:0:200})"
}

test_compose_file_created() {
    run_install "" > /dev/null 2>&1 || true
    local cf
    cf="$(compose_file)"
    assert_eq "exists" "$(test -f "$cf" && echo exists || echo missing)" "docker-compose.yaml created in STACK_DIR"
}

test_compose_contains_watchtower_image() {
    run_install "" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" "containrrr/watchtower" "compose uses containrrr/watchtower image"
}

test_compose_memory_limit_64m() {
    run_install "" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" "64M" "compose sets 64M memory limit"
}

test_compose_mounts_docker_sock() {
    run_install "" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" "/var/run/docker.sock" "compose mounts Docker socket"
}

# =============================================================================
# Default values tests
# =============================================================================

test_default_mode_is_monitor_only() {
    run_install "" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" 'WATCHTOWER_MONITOR_ONLY: "true"' "default mode is monitor-only"
}

test_default_schedule_is_sunday_9am() {
    run_install "" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" "0 0 9 * * 0" "default schedule is Sunday 09:00"
}

test_default_includes_stopped_false() {
    run_install "" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" 'WATCHTOWER_INCLUDE_STOPPED: "false"' "stopped containers excluded by default"
}

# =============================================================================
# Mode tests
# =============================================================================

test_update_mode_sets_monitor_only_false() {
    run_install "WATCHTOWER_MODE=update" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" 'WATCHTOWER_MONITOR_ONLY: "false"' "update mode disables monitor-only"
}

test_monitor_mode_output_says_monitor() {
    output=$(run_install "" 2>&1) || true
    assert_contains "$output" "monitor" "monitor mode output mentions monitor"
}

test_update_mode_output_says_auto_update() {
    output=$(run_install "WATCHTOWER_MODE=update" 2>&1) || true
    assert_contains "$output" "auto-update" "update mode output mentions auto-update"
}

# =============================================================================
# Custom schedule test
# =============================================================================

test_custom_schedule_is_used() {
    run_install "WATCHTOWER_SCHEDULE='0 0 3 * * 1'" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" "0 0 3 * * 1" "custom schedule is written to compose"
}

# =============================================================================
# Notification URL test
# =============================================================================

test_notification_url_embedded_in_compose() {
    run_install "NOTIFICATION_URL='ntfy://:testtoken@ntfy.example.com/topic'" > /dev/null 2>&1 || true
    local content
    content=$(cat "$(compose_file)" 2>/dev/null || echo "")
    assert_contains "$content" "ntfy.example.com" "NOTIFICATION_URL is embedded in compose"
}

test_output_warns_when_no_notification_url() {
    output=$(run_install "" 2>&1) || true
    assert_contains "$output" "silently" "warns when no NOTIFICATION_URL is set"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
