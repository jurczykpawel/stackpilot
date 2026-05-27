#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "$(uname -s)" != "Linux" ]; then
    echo "Skipped: libsecret tests run only on Linux"
    exit 0
fi
if ! command -v secret-tool >/dev/null 2>&1; then
    echo "Skipped: secret-tool not installed"
    exit 0
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    echo "Skipped: DBus session not available"
    exit 0
fi

PASS=0; FAIL=0; FAILED=()
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected='$1' actual='$2')"); fi; }
assert_exit() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected_exit=$1 actual=$2)"); fi; }

TEST_APP="stackpilot-test-$$"
export STACKPILOT_LIBSECRET_APP="$TEST_APP"

cleanup() {
    secret-tool clear app "$TEST_APP" key cloudflare_api_token 2>/dev/null || true
    secret-tool clear app "$TEST_APP" key cloudflare_account_id 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/keystore/backend-libsecret.sh"

test_available() { _backend_available; assert_exit 0 $? "libsecret available"; }
test_id() { local g; g=$(_backend_id); assert_eq "libsecret" "$g" "id is libsecret"; }
test_set_get_roundtrip() {
    _backend_set cloudflare_api_token "tok-$$"
    assert_exit 0 $? "set returns 0"
    local g; g=$(_backend_get cloudflare_api_token)
    assert_eq "tok-$$" "$g" "get returns stored value"
}
test_get_missing() { _backend_get nope_$$ >/dev/null 2>&1; assert_exit 1 $? "missing returns 1"; }
test_has() {
    _backend_has cloudflare_api_token; assert_exit 0 $? "has returns 0 existing"
    _backend_has nope_$$; assert_exit 1 $? "has returns 1 missing"
}
test_rm() {
    _backend_set cloudflare_account_id v >/dev/null
    _backend_rm cloudflare_account_id
    _backend_has cloudflare_account_id; assert_exit 1 $? "rm actually clears"
}
test_list() {
    _backend_set cloudflare_api_token v1 >/dev/null
    _backend_set cloudflare_account_id v2 >/dev/null
    local g; g=$(_backend_list | sort)
    local w; w=$(printf 'cloudflare_account_id\ncloudflare_api_token')
    assert_eq "$w" "$g" "list returns names"
}

test_available
test_id
test_set_get_roundtrip
test_get_missing
test_has
test_rm
test_list

echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ $FAIL -gt 0 ]; then printf '  %s\n' "${FAILED[@]}"; exit 1; fi
