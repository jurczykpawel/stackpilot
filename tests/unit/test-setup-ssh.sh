#!/bin/bash

# Tests for local/setup-ssh.sh
# Tests the config-writing logic in isolation (no real SSH calls)

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

export TOOLBOX_LANG=en
source "$REPO_ROOT/lib/i18n.sh"

# =============================================================================
# Load write_ssh_config from the actual setup-ssh.sh
# Extract only the function definition — avoids running the interactive script.
# =============================================================================

eval "$(awk '/^write_ssh_config\(\)/,/^}$/' "$REPO_ROOT/local/setup-ssh.sh")"

# Verify we actually loaded the real function (not a stale local copy)
if ! declare -f write_ssh_config > /dev/null 2>&1; then
    echo "ERROR: write_ssh_config not found in local/setup-ssh.sh — test setup failed" >&2
    exit 1
fi

# =============================================================================
# Tests
# =============================================================================

setup() {
    TEST_TMPDIR=$(mktemp -d)
    TEST_CONFIG="$TEST_TMPDIR/ssh_config"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

test_write_config_creates_entry() {
    write_ssh_config "$TEST_CONFIG" "myvps" "1.2.3.4" "22" "root" "$HOME/.ssh/id_ed25519"
    assert_true grep -q "^Host myvps$" "$TEST_CONFIG" "Host entry created"
    assert_true grep -q "HostName 1.2.3.4" "$TEST_CONFIG" "HostName set"
    assert_true grep -q "Port 22" "$TEST_CONFIG" "Port set"
    assert_true grep -q "User root" "$TEST_CONFIG" "User set"
    assert_true grep -q "ServerAliveInterval 60" "$TEST_CONFIG" "keepalive set"
}

test_write_config_skips_duplicate() {
    write_ssh_config "$TEST_CONFIG" "myvps" "1.2.3.4" "22" "root" "$HOME/.ssh/id_ed25519"
    local result
    write_ssh_config "$TEST_CONFIG" "myvps" "5.6.7.8" "22" "root" "$HOME/.ssh/id_ed25519" && result=0 || result=1
    assert_eq "1" "$result" "duplicate alias returns 1"
    local count
    count=$(grep -c "^Host myvps$" "$TEST_CONFIG")
    assert_eq "1" "$count" "only one entry in config"
}

test_write_config_multiple_aliases() {
    write_ssh_config "$TEST_CONFIG" "vps1" "1.1.1.1" "22" "root" "$HOME/.ssh/id_ed25519"
    write_ssh_config "$TEST_CONFIG" "vps2" "2.2.2.2" "2222" "admin" "$HOME/.ssh/id_ed25519"
    assert_true grep -q "^Host vps1$" "$TEST_CONFIG" "vps1 exists"
    assert_true grep -q "^Host vps2$" "$TEST_CONFIG" "vps2 exists"
    assert_true grep -q "Port 2222" "$TEST_CONFIG" "custom port for vps2"
}

test_write_config_creates_file_if_missing() {
    local new_config="$TEST_TMPDIR/subdir/ssh_config"
    mkdir -p "$TEST_TMPDIR/subdir"
    write_ssh_config "$new_config" "vps" "1.2.3.4" "22" "root" "$HOME/.ssh/id_ed25519"
    assert_eq "true" "$(test -f "$new_config" && echo true || echo false)" "config file created"
}

test_write_config_permissions() {
    write_ssh_config "$TEST_CONFIG" "vps" "1.2.3.4" "22" "root" "$HOME/.ssh/id_ed25519"
    local perms
    if [ "$(uname)" = "Darwin" ]; then
        perms=$(stat -f "%OLp" "$TEST_CONFIG")
    else
        perms=$(stat -c "%a" "$TEST_CONFIG")
    fi
    assert_eq "600" "$perms" "config file has 600 permissions"
}

test_server_marker_blocks_script() {
    # When /opt/stackpilot/.server-marker exists, setup-ssh.sh must exit non-zero
    # We simulate it by temporarily creating the marker and running the script
    local fake_marker="/opt/stackpilot/.server-marker"
    local created_dir=false
    if [ ! -d /opt/stackpilot ]; then
        sudo mkdir -p /opt/stackpilot 2>/dev/null && created_dir=true || true
    fi
    if [ -d /opt/stackpilot ] && sudo touch "$fake_marker" 2>/dev/null; then
        local exit_code=0
        TOOLBOX_LANG=en "$REPO_ROOT/local/setup-ssh.sh" > /dev/null 2>&1 || exit_code=$?
        sudo rm -f "$fake_marker"
        [ "$created_dir" = true ] && sudo rmdir /opt/stackpilot 2>/dev/null || true
        assert_eq "1" "$exit_code" "script exits 1 when server marker present"
    else
        # Cannot create marker (no sudo) — skip with a note
        assert_eq "true" "true" "SKIP: cannot create /opt/stackpilot/.server-marker without sudo"
    fi
}

run_tests "$0"
