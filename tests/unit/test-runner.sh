#!/bin/bash

# StackPilot - Unit Test Runner
# Minimal test harness for Bash unit tests.
#
# Usage:
#   source tests/unit/test-runner.sh
#   test_something() { assert_eq "a" "a" "values match"; }
#   run_tests
#
# Provides:
#   assert_eq EXPECTED ACTUAL [MESSAGE]
#   assert_not_eq UNEXPECTED ACTUAL [MESSAGE]
#   assert_contains HAYSTACK NEEDLE [MESSAGE]
#   assert_not_contains HAYSTACK NEEDLE [MESSAGE]
#   assert_exit_code EXPECTED COMMAND...
#   assert_true COMMAND... (exit code 0)
#   assert_false COMMAND... (exit code != 0)
#   setup() / teardown() — override in test file (tmpdir per test)
#   run_tests — discovers and runs all test_* functions

# Colors
_TR_RED='\033[0;31m'
_TR_GREEN='\033[0;32m'
_TR_YELLOW='\033[1;33m'
_TR_NC='\033[0m'
_TR_BOLD='\033[1m'

# Counters
_TR_PASS=0
_TR_FAIL=0
_TR_SKIP=0
_TR_TOTAL=0
_TR_CURRENT_TEST=""
_TR_TEST_FAILED=false

# Temp directory for the current test
TEST_TMPDIR=""

# =============================================================================
# ASSERTIONS
# =============================================================================

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="${3:-assert_eq}"
    _TR_TOTAL=$((_TR_TOTAL + 1))

    if [ "$expected" = "$actual" ]; then
        return 0
    else
        echo -e "    ${_TR_RED}FAIL${_TR_NC}: $message"
        echo "      expected: '$expected'"
        echo "      actual:   '$actual'"
        _TR_TEST_FAILED=true
        return 1
    fi
}

assert_not_eq() {
    local unexpected="$1"
    local actual="$2"
    local message="${3:-assert_not_eq}"
    _TR_TOTAL=$((_TR_TOTAL + 1))

    if [ "$unexpected" != "$actual" ]; then
        return 0
    else
        echo -e "    ${_TR_RED}FAIL${_TR_NC}: $message"
        echo "      should not be: '$unexpected'"
        _TR_TEST_FAILED=true
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-assert_contains}"
    _TR_TOTAL=$((_TR_TOTAL + 1))

    if echo "$haystack" | grep -qF "$needle"; then
        return 0
    else
        echo -e "    ${_TR_RED}FAIL${_TR_NC}: $message"
        echo "      haystack does not contain: '$needle'"
        echo "      haystack: '${haystack:0:200}'"
        _TR_TEST_FAILED=true
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-assert_not_contains}"
    _TR_TOTAL=$((_TR_TOTAL + 1))

    if ! echo "$haystack" | grep -qF "$needle"; then
        return 0
    else
        echo -e "    ${_TR_RED}FAIL${_TR_NC}: $message"
        echo "      haystack should not contain: '$needle'"
        _TR_TEST_FAILED=true
        return 1
    fi
}

assert_exit_code() {
    local expected="$1"
    shift
    local message="assert_exit_code ($*)"
    _TR_TOTAL=$((_TR_TOTAL + 1))

    "$@" > /dev/null 2>&1
    local actual=$?

    if [ "$actual" -eq "$expected" ]; then
        return 0
    else
        echo -e "    ${_TR_RED}FAIL${_TR_NC}: $message"
        echo "      expected exit code: $expected"
        echo "      actual exit code:   $actual"
        _TR_TEST_FAILED=true
        return 1
    fi
}

assert_true() {
    local message="assert_true ($*)"
    _TR_TOTAL=$((_TR_TOTAL + 1))

    if "$@" > /dev/null 2>&1; then
        return 0
    else
        echo -e "    ${_TR_RED}FAIL${_TR_NC}: $message"
        _TR_TEST_FAILED=true
        return 1
    fi
}

assert_false() {
    local message="assert_false ($*)"
    _TR_TOTAL=$((_TR_TOTAL + 1))

    if ! "$@" > /dev/null 2>&1; then
        return 0
    else
        echo -e "    ${_TR_RED}FAIL${_TR_NC}: $message"
        _TR_TEST_FAILED=true
        return 1
    fi
}

# =============================================================================
# SETUP / TEARDOWN
# =============================================================================

# Default setup — creates a tmpdir
setup() {
    TEST_TMPDIR=$(mktemp -d)
}

# Default teardown — removes tmpdir
teardown() {
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# =============================================================================
# TEST RUNNER
# =============================================================================

run_tests() {
    local test_file="${1:-}"
    local filter="${2:-}"

    echo ""
    echo -e "${_TR_BOLD}Running tests${_TR_NC}"
    if [ -n "$test_file" ]; then
        echo "  File: $(basename "$test_file")"
    fi
    echo ""

    # Discover test_* functions
    local tests
    tests=$(declare -F | grep ' test_' | awk '{print $3}' | sort)

    if [ -z "$tests" ]; then
        echo -e "  ${_TR_YELLOW}No tests found${_TR_NC}"
        return 0
    fi

    local pass=0
    local fail=0

    for test_name in $tests; do
        # Apply filter if provided
        if [ -n "$filter" ] && [[ "$test_name" != *"$filter"* ]]; then
            continue
        fi

        _TR_CURRENT_TEST="$test_name"
        _TR_TEST_FAILED=false
        _TR_TOTAL=0

        # Setup
        setup

        # Run test (allow failures without exiting)
        set +e
        "$test_name"
        local test_exit=$?
        set -e

        # Teardown
        teardown

        # Evaluate result
        if [ "$_TR_TEST_FAILED" = true ] || [ "$test_exit" -ne 0 ]; then
            echo -e "  ${_TR_RED}✗${_TR_NC} $test_name"
            fail=$((fail + 1))
        elif [ "$_TR_TOTAL" -eq 0 ]; then
            echo -e "  ${_TR_YELLOW}✗${_TR_NC} $test_name ${_TR_YELLOW}(no assertions — test is a no-op)${_TR_NC}"
            fail=$((fail + 1))
        else
            echo -e "  ${_TR_GREEN}✓${_TR_NC} $test_name"
            pass=$((pass + 1))
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local total=$((pass + fail))
    echo -e "  ${_TR_GREEN}$pass passed${_TR_NC}, ${_TR_RED}$fail failed${_TR_NC} (total: $total)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ "$fail" -gt 0 ]; then
        return 1
    fi
    return 0
}
