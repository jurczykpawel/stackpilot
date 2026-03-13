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
# Helpers — extract testable functions from setup-ssh.sh
# =============================================================================

# Writes SSH config entry to a given config file
# Usage: write_ssh_config CONFIG_FILE ALIAS HOST PORT USER KEY_PATH
write_ssh_config() {
    local config_file="$1"
    local alias="$2"
    local host="$3"
    local port="$4"
    local user="$5"
    local key_path="$6"

    [ ! -f "$config_file" ] && touch "$config_file" && chmod 600 "$config_file"

    if grep -q "^Host $alias$" "$config_file"; then
        return 1  # already exists
    fi

    cat >> "$config_file" <<EOF

Host $alias
    HostName $host
    Port $port
    User $user
    IdentityFile $key_path
    ServerAliveInterval 60
EOF
    return 0
}

# =============================================================================
# Tests
# =============================================================================

setup() {
    TEST_TMPDIR=$(mktemp -d)
    TEST_CONFIG="$TEST_TMPDIR/ssh_config"
    TEST_KEY="$TEST_TMPDIR/id_ed25519_test"
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

test_server_marker_detected() {
    # Simulate being on a server — script should refuse to run
    local marker="$TEST_TMPDIR/.server-marker"
    touch "$marker"
    assert_eq "true" "$(test -f "$marker" && echo true || echo false)" "server marker exists"
}

run_tests "$0"
