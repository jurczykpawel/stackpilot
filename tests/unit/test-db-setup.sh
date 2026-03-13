#!/bin/bash

# Tests for lib/db-setup.sh (non-interactive parts)

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

# Load i18n and cli-parser (db-setup depends on both)
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

source "$REPO_ROOT/lib/db-setup.sh"

# Reset DB variables and all test-affecting globals
_reset_db() {
    unset DB_HOST DB_PORT DB_NAME DB_SCHEMA DB_USER DB_PASS DB_SOURCE BUNDLED_DB_TYPE
    export DB_HOST="" DB_PORT="" DB_NAME="" DB_SCHEMA="" DB_USER="" DB_PASS="" DB_SOURCE="" BUNDLED_DB_TYPE=""
}

# Per-test setup/teardown — ensure no state leaks between tests
setup() {
    TEST_TMPDIR=$(mktemp -d)
    _reset_db
    unset YES_MODE
}

teardown() {
    unset YES_MODE
    _reset_db
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# =============================================================================
# fetch_database tests
# =============================================================================

test_fetch_database_custom_noop() {
    _reset_db
    DB_SOURCE="custom"
    DB_HOST="example.com"
    DB_USER="user"
    fetch_database "postgres" > /dev/null 2>&1
    local status=$?
    assert_eq "0" "$status" "custom source returns 0 (no-op)"
}

test_fetch_database_bundled_generates_creds() {
    _reset_db
    DB_SOURCE="bundled"
    BUNDLED_DB_TYPE="postgres"
    fetch_database "postgres" > /dev/null 2>&1
    local status=$?
    assert_eq "0" "$status" "bundled returns 0"
    assert_not_eq "" "$DB_USER" "bundled generates DB_USER"
    assert_not_eq "" "$DB_PASS" "bundled generates DB_PASS"
    assert_not_eq "" "$DB_NAME" "bundled generates DB_NAME"
}

test_fetch_database_unknown_source() {
    _reset_db
    DB_SOURCE="nonexistent"
    fetch_database "postgres" > /dev/null 2>&1
    local status=$?
    assert_not_eq "0" "$status" "unknown source returns non-zero"
}

# =============================================================================
# ask_database with CLI flags (non-interactive)
# =============================================================================

test_ask_database_custom_with_creds() {
    _reset_db
    DB_SOURCE="custom"
    DB_HOST="db.example.com"
    DB_NAME="mydb"
    DB_USER="admin"
    DB_PASS="secret"
    ask_database "postgres" "n8n" > /dev/null 2>&1
    local status=$?
    assert_eq "0" "$status" "custom with all creds returns 0"
    assert_eq "custom" "$DB_SOURCE" "DB_SOURCE remains custom"
}

test_ask_database_bundled_sets_type() {
    _reset_db
    DB_SOURCE="bundled"
    ask_database "postgres" "n8n" > /dev/null 2>&1
    assert_eq "postgres" "$BUNDLED_DB_TYPE" "bundled sets BUNDLED_DB_TYPE"
}

test_ask_database_shared_accepted() {
    _reset_db
    DB_SOURCE="shared"
    ask_database "postgres" "nocodb" > /dev/null 2>&1
    local status=$?
    assert_eq "0" "$status" "shared source is accepted"
    assert_eq "shared" "$DB_SOURCE" "DB_SOURCE is shared"
}

test_ask_database_yes_mode_requires_source() {
    _reset_db
    YES_MODE=true
    ask_database "postgres" "n8n" > /dev/null 2>&1
    local status=$?
    assert_not_eq "0" "$status" "yes mode without source returns error"
    unset YES_MODE
}

test_ask_database_schema_from_appname() {
    _reset_db
    DB_SOURCE="bundled"
    ask_database "postgres" "umami" > /dev/null 2>&1
    assert_eq "umami" "$DB_SCHEMA" "schema defaults to app name"
}

# =============================================================================
# Connection string helpers
# =============================================================================

test_get_postgres_url() {
    DB_HOST="localhost"
    DB_PORT="5432"
    DB_NAME="mydb"
    DB_USER="user"
    DB_PASS="pass"
    DB_SCHEMA="public"
    local url
    url=$(get_postgres_url)
    assert_eq "postgresql://user:pass@localhost:5432/mydb" "$url" "postgres URL without schema"
}

test_get_postgres_url_with_schema() {
    DB_HOST="localhost"
    DB_PORT="5432"
    DB_NAME="mydb"
    DB_USER="user"
    DB_PASS="pass"
    DB_SCHEMA="n8n"
    local url
    url=$(get_postgres_url)
    assert_contains "$url" "schema=n8n" "postgres URL with schema"
}

test_get_mysql_url() {
    DB_HOST="localhost"
    DB_PORT="3306"
    DB_NAME="wpdb"
    DB_USER="root"
    DB_PASS="pass"
    local url
    url=$(get_mysql_url)
    assert_eq "mysql://root:pass@localhost:3306/wpdb" "$url" "mysql URL"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
