#!/bin/bash

# Tests for lib/port-utils.sh

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

# Load i18n and server-exec (port-utils depends on it)
export TOOLBOX_LANG=en
source "$REPO_ROOT/lib/i18n.sh"

# Mock: force "on server" mode to avoid SSH calls
_ON_SERVER=true
is_on_server() { [ "$_ON_SERVER" = true ]; }
export _ON_SERVER
export -f is_on_server

# Put mocks on PATH
export PATH="$REPO_ROOT/tests/mocks:$PATH"

source "$REPO_ROOT/lib/port-utils.sh"

# =============================================================================
# find_free_port tests
# =============================================================================

test_find_free_port_default() {
    export MOCK_SS_PORTS="80 443"
    local port
    port=$(find_free_port)
    assert_eq "8000" "$port" "default base port 8000 is free"
}

test_find_free_port_custom_base() {
    export MOCK_SS_PORTS="80 443"
    local port
    port=$(find_free_port 3000)
    assert_eq "3000" "$port" "custom base port 3000 is free"
}

test_find_free_port_skips_used() {
    export MOCK_SS_PORTS="80 443 8000 8001 8002"
    local port
    port=$(find_free_port 8000)
    assert_eq "8003" "$port" "skips used ports 8000-8002"
}

test_find_free_port_all_low_used() {
    export MOCK_SS_PORTS="5000 5001 5002 5003 5004"
    local port
    port=$(find_free_port 5000)
    assert_eq "5005" "$port" "finds 5005 when 5000-5004 are used"
}

test_find_free_port_single_used() {
    export MOCK_SS_PORTS="9000"
    local port
    port=$(find_free_port 9000)
    assert_eq "9001" "$port" "skips single used port"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
