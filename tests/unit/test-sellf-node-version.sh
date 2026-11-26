#!/bin/bash

# Sellf starts through util.parseEnv (Node.js 20.12+). The update checks Node.js
# before it stops the application; the installer upgrades an older Node.js.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"

ORIGINAL_PATH="$PATH"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    mkdir -p "$TEST_TMPDIR/bin"
    export TOOLBOX_LANG=en
    source "$REPO_ROOT/apps/sellf/release-verify.sh"
}

teardown() {
    PATH="$ORIGINAL_PATH"
    rm -rf "$TEST_TMPDIR"
}

# A Node.js 18 stand-in: runs, but has no util.parseEnv
old_node() {
    printf '#!/bin/sh\n[ "$1" = --version ] && { echo v18.19.1; exit 0; }\necho "TypeError: parseEnv is not a function" >&2\nexit 1\n' > "$1"
    chmod +x "$1"
}

test_current_node_is_accepted() {
    assert_true sellf_node_ready "$(command -v node)"
}

test_old_node_is_refused_with_a_clear_message() {
    old_node "$TEST_TMPDIR/bin/node"
    local out rc=0
    out=$(sellf_node_ready "$TEST_TMPDIR/bin/node" 2>&1) || rc=$?
    assert_not_eq 0 "$rc" "old Node.js refused"
    assert_contains "$out" "v18.19.1" "found version named"
    assert_contains "$out" "20.12" "required version named"
}

test_missing_node_is_refused() {
    local rc=0
    sellf_node_ready "$TEST_TMPDIR/bin/none" >/dev/null 2>&1 || rc=$?
    assert_not_eq 0 "$rc"
}

test_update_checks_node_before_stopping_the_app() {
    local check stop
    check=$(grep -n '^sellf_node_ready' "$REPO_ROOT/apps/sellf/update.sh" | head -1 | cut -d: -f1)
    stop=$(grep -n 'pm2 stop \$PM2_NAME' "$REPO_ROOT/apps/sellf/update.sh" | head -1 | cut -d: -f1)
    assert_true test -n "$check"
    assert_true test "${check:-999999}" -lt "$stop"
}

test_installer_upgrades_node_without_parse_env() {
    assert_contains "$(cat "$REPO_ROOT/apps/sellf/install.sh")" 'if ! sellf_node_ready /usr/bin/node' "installer uses the same check"
}

run_tests "$0"
