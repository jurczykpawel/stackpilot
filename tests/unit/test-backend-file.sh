#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMPDIR_BASE="${TMPDIR:-/tmp}/stackpilot-keystore-test-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

export STACKPILOT_KEYSTORE_FILE_DIR="$TMPDIR_BASE/keys"
export STACKPILOT_KEYSTORE_FILE_ACK=1

PASS=0; FAIL=0; FAILED=()
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected='$1' actual='$2')"); fi; }
assert_exit() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected_exit=$1 actual=$2)"); fi; }

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/keystore/backend-file.sh"

test_available() {
    _backend_available
    assert_exit 0 $? "file backend always available"
}

test_id() {
    local got
    got=$(_backend_id)
    assert_eq "file" "$got" "id returns 'file'"
}

test_set_creates_file_with_0600() {
    _backend_set cloudflare_api_token "secret-value"
    assert_exit 0 $? "set returns 0"
    local f="$STACKPILOT_KEYSTORE_FILE_DIR/cloudflare_api_token"
    if [ -f "$f" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1)); FAILED+=("file not created at $f")
    fi
    local perms
    perms=$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)
    assert_eq "600" "$perms" "file perms are 0600"
}

test_set_creates_dir_with_0700() {
    local perms
    perms=$(stat -f '%Lp' "$STACKPILOT_KEYSTORE_FILE_DIR" 2>/dev/null || stat -c '%a' "$STACKPILOT_KEYSTORE_FILE_DIR" 2>/dev/null)
    assert_eq "700" "$perms" "dir perms are 0700"
}

test_get_returns_value() {
    local got
    got=$(_backend_get cloudflare_api_token)
    assert_eq "secret-value" "$got" "get returns stored value"
}

test_get_returns_1_when_missing() {
    _backend_get nonexistent_key >/dev/null 2>&1
    assert_exit 1 $? "get returns 1 when missing"
}

test_has() {
    _backend_has cloudflare_api_token
    assert_exit 0 $? "has returns 0 for existing"
    _backend_has nonexistent_key
    assert_exit 1 $? "has returns 1 for missing"
}

test_rm_idempotent() {
    _backend_rm nonexistent_key
    assert_exit 0 $? "rm of missing returns 0"
    _backend_rm cloudflare_api_token
    _backend_has cloudflare_api_token
    assert_exit 1 $? "rm of existing actually removes"
}

test_list() {
    _backend_set cloudflare_api_token v1 >/dev/null
    _backend_set cloudflare_account_id v2 >/dev/null
    local got
    got=$(_backend_list | sort)
    local want
    want=$(printf 'cloudflare_account_id\ncloudflare_api_token')
    assert_eq "$want" "$got" "list returns all stored names"
}

test_available
test_id
test_set_creates_file_with_0600
test_set_creates_dir_with_0700
test_get_returns_value
test_get_returns_1_when_missing
test_has
test_rm_idempotent
test_list

echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ $FAIL -gt 0 ]; then printf '  %s\n' "${FAILED[@]}"; exit 1; fi
