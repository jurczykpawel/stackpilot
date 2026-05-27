#!/bin/bash
# Tests for lib/keystore/core.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export STACKPILOT_KEYSTORE_BACKEND_OVERRIDE_PATH="$REPO_ROOT/tests/_helpers/mock-backend.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$msg (expected='$expected' actual='$actual')")
    fi
}

assert_exit() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$msg (expected exit=$expected actual exit=$actual)")
    fi
}

run_in_subshell() {
    (
        # shellcheck source=/dev/null
        source "$STACKPILOT_KEYSTORE_BACKEND_OVERRIDE_PATH"
        mock_backend_reset
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/keystore/core.sh"
        "$@"
    )
}

test_set_rejects_invalid_name() {
    run_in_subshell keystore_set "Foo Bar" "value" 2>/dev/null
    assert_exit 2 $? "set rejects names with spaces"
    run_in_subshell keystore_set "UPPER" "value" 2>/dev/null
    assert_exit 2 $? "set rejects uppercase names"
    run_in_subshell keystore_set "9starts" "value" 2>/dev/null
    assert_exit 2 $? "set rejects names starting with digit"
}

test_set_rejects_empty_value() {
    run_in_subshell keystore_set "cloudflare_api_token" "" 2>/dev/null
    assert_exit 2 $? "set rejects empty value"
}

test_set_get_roundtrip() {
    local got
    got=$(
        # shellcheck source=/dev/null
        source "$STACKPILOT_KEYSTORE_BACKEND_OVERRIDE_PATH"
        mock_backend_reset
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/keystore/core.sh"
        keystore_set cloudflare_api_token "tok-123" >/dev/null
        keystore_get cloudflare_api_token
    )
    assert_eq "tok-123" "$got" "set then get returns same value"
}

test_has_returns_1_when_missing() {
    run_in_subshell keystore_has cloudflare_api_token
    assert_exit 1 $? "has returns 1 when key not set"
}

test_rm_is_idempotent() {
    run_in_subshell keystore_rm cloudflare_api_token
    assert_exit 0 $? "rm of missing key still succeeds"
    local rc
    (
        # shellcheck source=/dev/null
        source "$STACKPILOT_KEYSTORE_BACKEND_OVERRIDE_PATH"
        mock_backend_reset
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/keystore/core.sh"
        keystore_set cloudflare_api_token v >/dev/null
        keystore_rm cloudflare_api_token
        keystore_has cloudflare_api_token
    )
    rc=$?
    assert_exit 1 "$rc" "rm removes existing key"
}

test_list_returns_stored_names() {
    local got
    got=$(
        # shellcheck source=/dev/null
        source "$STACKPILOT_KEYSTORE_BACKEND_OVERRIDE_PATH"
        mock_backend_reset
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/keystore/core.sh"
        keystore_set cloudflare_api_token v1 >/dev/null
        keystore_set cloudflare_account_id v2 >/dev/null
        keystore_list | sort
    )
    local want
    want=$(printf 'cloudflare_account_id\ncloudflare_api_token')
    assert_eq "$want" "$got" "list returns set names sorted"
}

test_require_keys_reports_missing() {
    local got
    got=$(
        # shellcheck source=/dev/null
        source "$STACKPILOT_KEYSTORE_BACKEND_OVERRIDE_PATH"
        mock_backend_reset
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/keystore/core.sh"
        keystore_set cloudflare_api_token v >/dev/null
        keystore_require_keys cloudflare_api_token cloudflare_account_id 2>/dev/null
    )
    assert_eq "cloudflare_account_id" "$got" "require_keys outputs only missing names"
}

test_require_keys_exits_with_count() {
    (
        # shellcheck source=/dev/null
        source "$STACKPILOT_KEYSTORE_BACKEND_OVERRIDE_PATH"
        mock_backend_reset
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/keystore/core.sh"
        keystore_require_keys cloudflare_api_token cloudflare_account_id >/dev/null 2>&1
    )
    assert_exit 2 $? "require_keys exit = count of missing"
}

test_backend_returns_id() {
    local got
    got=$(run_in_subshell keystore_backend)
    assert_eq "mock" "$got" "backend returns mock id"
}

test_set_rejects_invalid_name
test_set_rejects_empty_value
test_set_get_roundtrip
test_has_returns_1_when_missing
test_rm_is_idempotent
test_list_returns_stored_names
test_require_keys_reports_missing
test_require_keys_exits_with_count
test_backend_returns_id

echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ $FAIL -gt 0 ]; then
    printf '  %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
