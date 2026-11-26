#!/bin/bash

# apps/n8n/install.sh: the database message matches the selected database mode.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/apps/n8n/install.sh"

source "$TESTS_DIR/test-runner.sh"

# Only the banner before the first command that touches the server matters here.
banner() {
    sed -n '/^echo "--- .*n8n Setup/,/^# 1\. /p' "$INSTALL_SH" > "$TEST_TMPDIR/banner.sh"
    env -i PATH="$PATH" "$@" bash "$TEST_TMPDIR/banner.sh" 2>&1
}

test_bundled_mode_does_not_claim_an_external_database() {
    local out
    out=$(banner BUNDLED_DB_TYPE=postgres)
    assert_not_contains "$out" "External PostgreSQL" "bundled mode banner"
    assert_contains "$out" "bundled PostgreSQL" "bundled mode named"
}

test_external_mode_names_the_external_database() {
    local out
    out=$(banner)
    assert_contains "$out" "external PostgreSQL" "external mode banner"
}

run_tests "$0"
