#!/bin/bash

# installers/build.sh publishes a one-liner only for apps that can install from it.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

build() {
    bash "$REPO_ROOT/installers/build.sh" "$TEST_TMPDIR/out" > "$TEST_TMPDIR/build.log" 2>&1
}

test_apps_marked_without_oneliner_get_no_endpoint() {
    build
    assert_false test -e "$TEST_TMPDIR/out/mailstack"
    assert_false test -e "$TEST_TMPDIR/out/mailcheap"
    assert_not_contains "$(cat "$TEST_TMPDIR/out/_headers")" "/mailstack" "no headers entry for mailstack"
    assert_not_contains "$(cat "$TEST_TMPDIR/out/_headers")" "/mailcheap" "no headers entry for mailcheap"
}

test_regular_apps_keep_their_endpoint() {
    build
    assert_true test -f "$TEST_TMPDIR/out/n8n"
    assert_contains "$(cat "$TEST_TMPDIR/out/n8n")" 'APP="n8n"' "n8n one-liner rendered"
}

test_a_previously_published_endpoint_is_removed() {
    mkdir -p "$TEST_TMPDIR/out"
    echo old > "$TEST_TMPDIR/out/mailstack"
    build
    assert_false test -e "$TEST_TMPDIR/out/mailstack"
}

test_apps_installed_from_a_local_build_carry_the_marker() {
    local dir app missing=""
    for dir in "$REPO_ROOT"/apps/*/; do
        app=$(basename "$dir")
        if [ -f "$dir/deploy.mjs" ] || [ -f "$dir/build.sh" ]; then
            grep -qx '# ONELINER=false' "$dir/install.sh" || missing="$missing $app"
        fi
    done
    assert_eq "" "$missing" "apps with deploy.mjs or build.sh are marked ONELINER=false"
}

run_tests "$0"
