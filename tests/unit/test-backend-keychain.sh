#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Skipped: keychain backend tests run only on macOS"
    exit 0
fi
if ! command -v security >/dev/null 2>&1; then
    echo "Skipped: security CLI not found"
    exit 0
fi

PASS=0; FAIL=0; FAILED=()
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected='$1' actual='$2')"); fi; }
assert_exit() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected_exit=$1 actual=$2)"); fi; }

TEST_SERVICE="stackpilot-test-$$"
export STACKPILOT_KEYCHAIN_SERVICE="$TEST_SERVICE"

cleanup() {
    security delete-generic-password -s "$TEST_SERVICE" -a cloudflare_api_token >/dev/null 2>&1 || true
    security delete-generic-password -s "$TEST_SERVICE" -a cloudflare_account_id >/dev/null 2>&1 || true
}
trap cleanup EXIT

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/keystore/backend-keychain.sh"

test_available() {
    _backend_available
    assert_exit 0 $? "keychain backend available on macOS"
}

test_id() {
    local got
    got=$(_backend_id)
    assert_eq "keychain" "$got" "id returns 'keychain'"
}

test_set_then_get() {
    _backend_set cloudflare_api_token "tok-$$"
    assert_exit 0 $? "set returns 0"
    local got
    got=$(_backend_get cloudflare_api_token)
    assert_eq "tok-$$" "$got" "get returns same value"
}

test_get_missing_returns_1() {
    _backend_get nonexistent_$$ >/dev/null 2>&1
    assert_exit 1 $? "get missing returns 1"
}

test_has() {
    _backend_has cloudflare_api_token
    assert_exit 0 $? "has returns 0 for existing"
    _backend_has nonexistent_$$
    assert_exit 1 $? "has returns 1 for missing"
}

test_rm() {
    _backend_set cloudflare_account_id "acc-$$" >/dev/null
    _backend_rm cloudflare_account_id
    _backend_has cloudflare_account_id
    assert_exit 1 $? "rm actually removes"
    _backend_rm nonexistent_$$
    assert_exit 0 $? "rm idempotent for missing"
}

test_set_update() {
    _backend_set cloudflare_api_token "first" >/dev/null
    _backend_set cloudflare_api_token "second" >/dev/null
    local got
    got=$(_backend_get cloudflare_api_token)
    assert_eq "second" "$got" "set overwrites existing"
}

test_list() {
    _backend_set cloudflare_api_token v1 >/dev/null
    _backend_set cloudflare_account_id v2 >/dev/null
    local got
    got=$(_backend_list | sort)
    local want
    want=$(printf 'cloudflare_account_id\ncloudflare_api_token')
    assert_eq "$want" "$got" "list returns names from our service only"
}

test_available
test_id
test_set_then_get
test_get_missing_returns_1
test_has
test_rm
test_set_update
test_list

echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ $FAIL -gt 0 ]; then printf '  %s\n' "${FAILED[@]}"; exit 1; fi
