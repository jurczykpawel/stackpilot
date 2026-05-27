#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Skipped: python3 not available for mock server"
    exit 0
fi

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/_helpers/mock-cf-server.sh"

PASS=0; FAIL=0; FAILED=()
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected='$1' actual='$2')"); fi; }
assert_exit() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected=$1 actual=$2)"); fi; }

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/wizards/_helpers.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/wizards/_contract.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/wizards/cloudflare.sh"

test_required_keys_returns_two_names() {
    local got
    got=$(wizard_required_keys | sort)
    local want
    want=$(printf 'cloudflare_account_id\ncloudflare_api_token')
    assert_eq "$want" "$got" "required keys: api_token + account_id"
}

test_contract_compliance() {
    wizard_assert_contract_or_die cloudflare 2>/dev/null
    assert_exit 0 $? "cloudflare wizard implements all 4 contract functions"
}

test_validate_ok_against_mock() {
    mock_cf_start ok || { FAIL=$((FAIL+1)); FAILED+=("mock failed to start"); return; }
    export STACKPILOT_CF_API_URL="http://127.0.0.1:$MOCK_CF_PORT"
    wizard_validate cloudflare_api_token "fake-token-ok" >/dev/null 2>&1
    local rc=$?
    assert_exit 0 "$rc" "validate returns 0 for ok scenario"
    mock_cf_stop
}

test_validate_invalid_token() {
    mock_cf_start invalid_token || { FAIL=$((FAIL+1)); FAILED+=("mock failed to start"); return; }
    export STACKPILOT_CF_API_URL="http://127.0.0.1:$MOCK_CF_PORT"
    local err rc
    err=$(wizard_validate cloudflare_api_token "bad-token" 2>&1)
    rc=$?
    assert_exit 2 "$rc" "validate returns 2 for invalid token"
    case "$err" in
        *"STACKPILOT_ERR"*"code=2"*"provider=cloudflare"*) PASS=$((PASS+1)) ;;
        *) FAIL=$((FAIL+1)); FAILED+=("expected STACKPILOT_ERR code=2, got: $err") ;;
    esac
    mock_cf_stop
}

test_validate_missing_r2_scope() {
    mock_cf_start missing_r2_scope || { FAIL=$((FAIL+1)); FAILED+=("mock failed to start"); return; }
    export STACKPILOT_CF_API_URL="http://127.0.0.1:$MOCK_CF_PORT"
    local err rc
    err=$(wizard_validate cloudflare_api_token "scope-missing-token" 2>&1)
    rc=$?
    assert_exit 4 "$rc" "validate returns 4 for missing scope"
    case "$err" in
        *"code=4"*"R2"*) PASS=$((PASS+1)) ;;
        *) FAIL=$((FAIL+1)); FAILED+=("expected R2-missing detail, got: $err") ;;
    esac
    mock_cf_stop
}

test_validate_account_id_format() {
    # 32 hex chars = OK
    wizard_validate cloudflare_account_id "0123456789abcdef0123456789abcdef" >/dev/null 2>&1
    assert_exit 0 $? "account_id 32 hex valid"
    # Wrong length
    wizard_validate cloudflare_account_id "short" >/dev/null 2>&1
    assert_exit 2 $? "account_id too short rejected"
    # Uppercase
    wizard_validate cloudflare_account_id "0123456789ABCDEF0123456789ABCDEF" >/dev/null 2>&1
    assert_exit 2 $? "account_id uppercase rejected"
}

trap mock_cf_stop EXIT

test_required_keys_returns_two_names
test_contract_compliance
test_validate_ok_against_mock
test_validate_invalid_token
test_validate_missing_r2_scope
test_validate_account_id_format

echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ $FAIL -gt 0 ]; then printf '  %s\n' "${FAILED[@]}"; exit 1; fi
