#!/bin/bash

# Tests for lib/domain-setup.sh (non-interactive parts)

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

# Load i18n and cli-parser
export TOOLBOX_LANG=en
source "$REPO_ROOT/lib/i18n.sh"
source "$REPO_ROOT/lib/cli-parser.sh"

# Put mocks on PATH
export PATH="$REPO_ROOT/tests/mocks:$PATH"

# Mock server-exec
_ON_SERVER=true
is_on_server() { [ "$_ON_SERVER" = true ]; }
server_exec() { bash -c "$1"; }
export _ON_SERVER
export -f is_on_server server_exec

# Mock provider hooks (generic)
provider_domain_options() { return 0; }
export -f provider_domain_options

source "$REPO_ROOT/lib/domain-setup.sh"

# Reset
_reset_domain() {
    unset DOMAIN DOMAIN_TYPE YES_MODE
    export DOMAIN="" DOMAIN_TYPE=""
}

# =============================================================================
# ask_domain (CLI mode — DOMAIN_TYPE already set)
# =============================================================================

test_domain_type_local() {
    _reset_domain
    DOMAIN_TYPE="local"
    ask_domain "testapp" "8080" > /dev/null 2>&1
    local status=$?
    assert_eq "0" "$status" "local domain type returns 0"
    assert_eq "local" "$DOMAIN_TYPE" "DOMAIN_TYPE stays local"
}

test_domain_type_local_clears_auto() {
    _reset_domain
    DOMAIN_TYPE="local"
    DOMAIN="auto"
    ask_domain "testapp" "8080" > /dev/null 2>&1
    assert_eq "" "$DOMAIN" "auto domain cleared for local"
}

test_domain_type_cloudflare_with_domain() {
    _reset_domain
    DOMAIN_TYPE="cloudflare"
    DOMAIN="app.example.com"
    # Point CLOUDFLARE_CONFIG to a fake file with example.com so validation passes
    local OLD_CF_CONFIG="$CLOUDFLARE_CONFIG"
    CLOUDFLARE_CONFIG="$TEST_TMPDIR/cf-config"
    echo "example.com=zone123" > "$CLOUDFLARE_CONFIG"
    ask_domain "testapp" "8080" > /dev/null 2>&1
    local status=$?
    CLOUDFLARE_CONFIG="$OLD_CF_CONFIG"
    assert_eq "0" "$status" "cloudflare with domain returns 0"
    assert_eq "app.example.com" "$DOMAIN" "domain preserved"
}

test_domain_type_caddy_with_domain() {
    _reset_domain
    DOMAIN_TYPE="caddy"
    DOMAIN="app.example.com"
    ask_domain "testapp" "8080" > /dev/null 2>&1
    local status=$?
    assert_eq "0" "$status" "caddy with domain returns 0"
}

test_domain_type_invalid() {
    _reset_domain
    DOMAIN_TYPE="invalid"
    ask_domain "testapp" "8080" > /dev/null 2>&1
    local status=$?
    assert_not_eq "0" "$status" "invalid domain type returns error"
}

test_domain_type_cytrus() {
    _reset_domain
    DOMAIN_TYPE="cytrus"
    DOMAIN="auto"
    ask_domain "testapp" "8080" > /dev/null 2>&1
    local status=$?
    assert_eq "0" "$status" "cytrus domain type returns 0"
    assert_eq "-" "$DOMAIN" "auto becomes dash for cytrus"
}

test_domain_type_cytrus_explicit() {
    _reset_domain
    DOMAIN_TYPE="cytrus"
    DOMAIN="myapp.byst.re"
    ask_domain "testapp" "8080" > /dev/null 2>&1
    local status=$?
    assert_eq "0" "$status" "cytrus with explicit domain returns 0"
    assert_eq "myapp.byst.re" "$DOMAIN" "explicit cytrus domain preserved"
}

test_yes_mode_requires_domain_type() {
    _reset_domain
    YES_MODE=true
    ask_domain "testapp" "8080" > /dev/null 2>&1
    local status=$?
    assert_not_eq "0" "$status" "yes mode without domain type returns error"
    unset YES_MODE
}

test_cloudflare_yes_requires_domain() {
    _reset_domain
    DOMAIN_TYPE="cloudflare"
    YES_MODE=true
    ask_domain "testapp" "8080" > /dev/null 2>&1
    local status=$?
    assert_not_eq "0" "$status" "cloudflare in yes mode without domain returns error"
    unset YES_MODE
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
