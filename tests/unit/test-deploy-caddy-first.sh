#!/bin/bash

# deploy.sh installs Caddy before the app installer when the domain goes through Caddy.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

BLOCK=$(sed -n '/^# Installers find Caddy/,/^fi$/p' "$REPO_ROOT/local/deploy.sh")

run_block() {
    (
        NEEDS_DOMAIN="$1" DOMAIN_TYPE="$2" SSH_ALIAS=vps
        ensure_caddy() { echo "ensure_caddy $1" >> "$TEST_TMPDIR/calls"; return "${CADDY_RESULT:-0}"; }
        eval "$BLOCK"
        echo continued >> "$TEST_TMPDIR/calls"
    )
}

test_block_exists_before_the_installer_runs() {
    local block_line upload_line
    block_line=$(grep -n '^# Installers find Caddy' "$REPO_ROOT/local/deploy.sh" | cut -d: -f1)
    upload_line=$(grep -n '^# Upload script to server and execute' "$REPO_ROOT/local/deploy.sh" | cut -d: -f1)
    assert_true test -n "$block_line"
    assert_true test "${block_line:-0}" -lt "$upload_line"
}

test_caddy_and_cloudflare_domains_install_caddy_first() {
    run_block true caddy
    run_block true cloudflare
    assert_eq "$(printf 'ensure_caddy vps\ncontinued\nensure_caddy vps\ncontinued')" "$(cat "$TEST_TMPDIR/calls")"
}

test_other_domain_types_skip_caddy() {
    run_block true local
    run_block true cytrus
    run_block false caddy
    assert_eq "$(printf 'continued\ncontinued\ncontinued')" "$(cat "$TEST_TMPDIR/calls")"
}

test_deploy_stops_when_caddy_cannot_be_installed() {
    CADDY_RESULT=1 run_block true caddy || true
    assert_eq "ensure_caddy vps" "$(cat "$TEST_TMPDIR/calls")" "installer does not run without Caddy"
}

test_littlelink_installer_leaves_caddy_to_deploy() {
    assert_not_contains "$(cat "$REPO_ROOT/apps/littlelink/install.sh")" "command -v caddy" "no Caddy check in the installer"
}

run_tests "$0"
