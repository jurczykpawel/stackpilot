#!/bin/bash

# Tests for lib/cli-parser.sh

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

# Load i18n first (cli-parser uses msg())
export TOOLBOX_LANG=en
source "$REPO_ROOT/lib/i18n.sh"
source "$REPO_ROOT/lib/cli-parser.sh"

# Reset all variables between tests
_reset_vars() {
    unset SSH_ALIAS DB_SOURCE DB_HOST DB_PORT DB_NAME DB_SCHEMA DB_USER DB_PASS
    unset DOMAIN DOMAIN_TYPE SUPABASE_PROJECT INSTANCE APP_PORT
    unset YES_MODE DRY_RUN UPDATE_MODE RESTART_ONLY BUILD_FILE
    POSITIONAL_ARGS=()
}

# =============================================================================
# parse_args tests
# =============================================================================

test_parse_ssh_equals() {
    _reset_vars
    parse_args --ssh=myserver
    assert_eq "myserver" "$SSH_ALIAS" "--ssh=value sets SSH_ALIAS"
}

test_parse_ssh_space() {
    _reset_vars
    parse_args --ssh myserver
    assert_eq "myserver" "$SSH_ALIAS" "--ssh value sets SSH_ALIAS"
}

test_parse_db_source() {
    _reset_vars
    parse_args --db-source=bundled
    assert_eq "bundled" "$DB_SOURCE" "--db-source=bundled"
}

test_parse_db_full() {
    _reset_vars
    parse_args --db-host=db.example.com --db-port=5433 --db-name=mydb --db-user=admin --db-pass=secret --db-schema=app
    assert_eq "db.example.com" "$DB_HOST" "DB_HOST"
    assert_eq "5433" "$DB_PORT" "DB_PORT"
    assert_eq "mydb" "$DB_NAME" "DB_NAME"
    assert_eq "admin" "$DB_USER" "DB_USER"
    assert_eq "secret" "$DB_PASS" "DB_PASS"
    assert_eq "app" "$DB_SCHEMA" "DB_SCHEMA"
}

test_parse_domain() {
    _reset_vars
    parse_args --domain=app.example.com --domain-type=cloudflare
    assert_eq "app.example.com" "$DOMAIN" "DOMAIN"
    assert_eq "cloudflare" "$DOMAIN_TYPE" "DOMAIN_TYPE"
}

test_parse_yes_mode() {
    _reset_vars
    parse_args --yes
    assert_eq "true" "$YES_MODE" "--yes sets YES_MODE"
}

test_parse_y_shorthand() {
    _reset_vars
    parse_args -y
    assert_eq "true" "$YES_MODE" "-y sets YES_MODE"
}

test_parse_dry_run() {
    _reset_vars
    parse_args --dry-run
    assert_eq "true" "$DRY_RUN" "--dry-run sets DRY_RUN"
}

test_parse_update_mode() {
    _reset_vars
    parse_args --update
    assert_eq "true" "$UPDATE_MODE" "--update sets UPDATE_MODE"
}

test_parse_restart() {
    _reset_vars
    parse_args --restart
    assert_eq "true" "$RESTART_ONLY" "--restart sets RESTART_ONLY"
}

test_parse_positional_args() {
    _reset_vars
    parse_args n8n --ssh=vps --yes extra
    assert_eq "n8n" "${POSITIONAL_ARGS[0]}" "first positional arg"
    assert_eq "extra" "${POSITIONAL_ARGS[1]}" "second positional arg"
    assert_eq "vps" "$SSH_ALIAS" "SSH_ALIAS with positional"
}

test_parse_instance_and_port() {
    _reset_vars
    parse_args --instance=sellf-demo --port=3334
    assert_eq "sellf-demo" "$INSTANCE" "INSTANCE"
    assert_eq "3334" "$APP_PORT" "APP_PORT"
}

test_parse_combined_flags() {
    _reset_vars
    parse_args wordpress --ssh=prod --domain-type=cloudflare --domain=blog.example.com --db-source=bundled --yes
    assert_eq "wordpress" "${POSITIONAL_ARGS[0]}" "app name"
    assert_eq "prod" "$SSH_ALIAS" "SSH_ALIAS"
    assert_eq "cloudflare" "$DOMAIN_TYPE" "DOMAIN_TYPE"
    assert_eq "blog.example.com" "$DOMAIN" "DOMAIN"
    assert_eq "bundled" "$DB_SOURCE" "DB_SOURCE"
    assert_eq "true" "$YES_MODE" "YES_MODE"
}

test_parse_unknown_flag_exits() {
    _reset_vars
    local output rc
    output=$(parse_args --unknown-flag 2>&1); rc=$?
    assert_not_eq "" "$output" "unknown flag produces error output"
    assert_not_eq "0" "$rc" "unknown flag exits non-zero"
}

# =============================================================================
# load_defaults tests
# =============================================================================

test_defaults_ssh_alias() {
    _reset_vars
    load_defaults
    assert_eq "vps" "$SSH_ALIAS" "default SSH_ALIAS is vps"
}

test_defaults_db_port() {
    _reset_vars
    load_defaults
    assert_eq "5432" "$DB_PORT" "default DB_PORT is 5432"
}

test_defaults_db_schema() {
    _reset_vars
    load_defaults
    assert_eq "public" "$DB_SCHEMA" "default DB_SCHEMA is public"
}

test_defaults_no_domain_type() {
    _reset_vars
    load_defaults
    assert_eq "" "$DOMAIN_TYPE" "default DOMAIN_TYPE is empty"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
