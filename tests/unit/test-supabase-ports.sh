#!/bin/bash

# Unit tests for the port binding applied by apps/supabase/install.sh to the downloaded compose file.
# Fixtures are the port blocks recorded from upstream Supabase.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/apps/supabase/install.sh"
CURRENT="$TESTS_DIR/fixtures/supabase-ports-current.yml"
OLDER="$TESTS_DIR/fixtures/supabase-ports-v1.24.09.yml"

source "$TESTS_DIR/test-runner.sh"

sudo() { "$@"; }
eval "$(sed -n '/^bind_gateway_ports() {$/,/^}$/p' "$INSTALL_SH")"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    COMPOSE="$TEST_TMPDIR/docker-compose.yml"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

bind() { BIND_ADDR="$1" bind_gateway_ports "$COMPOSE"; }
ports() { grep -E '^      - ' "$COMPOSE"; }

test_current_gateway_binds_to_localhost_and_pooler_stays() {
    cp "$CURRENT" "$COMPOSE"
    assert_true bind "127.0.0.1:"
    assert_eq '      - 127.0.0.1:${API_GW_HTTP_PORT:-${KONG_HTTP_PORT:-8000}}:8000/tcp
      - ${POSTGRES_PORT}:5432
      - ${POOLER_PROXY_PORT_TRANSACTION}:6543' "$(ports)" "only the HTTP gateway changes"
}

test_older_gateway_https_and_analytics_bind_to_localhost() {
    cp "$OLDER" "$COMPOSE"
    assert_true bind "127.0.0.1:"
    assert_eq '      - 127.0.0.1:${KONG_HTTP_PORT}:8000/tcp
      - 127.0.0.1:${KONG_HTTPS_PORT}:8443/tcp
      - 127.0.0.1:4000:4000
      - ${POSTGRES_PORT}:${POSTGRES_PORT}
      - ${POOLER_PROXY_PORT_TRANSACTION}:${POOLER_PROXY_PORT_TRANSACTION}' "$(ports)" "every HTTP port changes"
}

test_cytrus_leaves_the_file_as_downloaded() {
    cp "$CURRENT" "$COMPOSE"
    assert_true bind ""
    assert_true cmp -s "$CURRENT" "$COMPOSE"
}

test_reinstall_follows_the_selected_domain_type() {
    cp "$OLDER" "$COMPOSE"
    bind "127.0.0.1:"
    bind "127.0.0.1:"
    assert_eq 3 "$(grep -c -- '- 127.0.0.1:' "$COMPOSE")" "repeated install adds one prefix"
    bind ""
    assert_true cmp -s "$OLDER" "$COMPOSE"
}

test_unknown_port_format_is_an_error() {
    printf 'services:\n  api-gw:\n    ports:\n      - "${API_GW_HTTP_PORT}:8000/tcp"\n' > "$COMPOSE"
    assert_false bind "127.0.0.1:"
}

run_tests "$0"
