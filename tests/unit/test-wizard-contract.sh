#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0; FAILED=()
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected='$1' actual='$2')"); fi; }

test_helpers_emit_error_format() {
    local got
    got=$(
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/wizards/_helpers.sh"
        emit_error 2 cloudflare cloudflare_api_token "API returned 401" "token revoked" 2>&1
    )
    local expected='STACKPILOT_ERR code=2 provider=cloudflare key=cloudflare_api_token detail="API returned 401" hint="token revoked"'
    assert_eq "$expected" "$got" "emit_error format"
}

test_contract_passes_when_all_funcs_defined() {
    local rc
    (
        wizard_required_keys() { :; }
        wizard_check() { :; }
        wizard_validate() { :; }
        wizard_run() { :; }
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/wizards/_contract.sh"
        wizard_assert_contract_or_die test-provider
    ) 2>/dev/null
    rc=$?
    if [ $rc -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("contract should pass when all 4 funcs defined (rc=$rc)"); fi
}

test_contract_fails_when_missing_func() {
    local rc
    (
        wizard_required_keys() { :; }
        wizard_validate() { :; }
        wizard_run() { :; }
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/wizards/_contract.sh"
        wizard_assert_contract_or_die test-provider
    ) 2>/dev/null
    rc=$?
    if [ $rc -ne 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("contract should fail when wizard_check missing"); fi
}

test_helpers_emit_error_format
test_contract_passes_when_all_funcs_defined
test_contract_fails_when_missing_func

echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ $FAIL -gt 0 ]; then printf '  %s\n' "${FAILED[@]}"; exit 1; fi
