#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMPDIR_BASE="${TMPDIR:-/tmp}/stackpilot-keys-cli-test-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

export STACKPILOT_KEYSTORE=file
export STACKPILOT_KEYSTORE_FILE_DIR="$TMPDIR_BASE/keys"
export STACKPILOT_KEYSTORE_FILE_ACK=1

CLI="$REPO_ROOT/local/keys.sh"
PASS=0; FAIL=0; FAILED=()
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected='$1' actual='$2')"); fi; }
assert_exit() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected_exit=$1 actual=$2)"); fi; }

test_backend_subcommand() {
    local g
    g=$(bash "$CLI" backend | head -1 | tr -d '[:space:]')
    assert_eq "file" "$g" "backend subcommand prints active backend"
}

test_list_empty_initially() {
    local g
    g=$(bash "$CLI" list 2>/dev/null)
    case "$g" in
        *"no keys"*|"") PASS=$((PASS+1)) ;;
        *) FAIL=$((FAIL+1)); FAILED+=("list should report empty, got: $g") ;;
    esac
}

test_get_missing_returns_1() {
    bash "$CLI" get cloudflare_api_token >/dev/null 2>&1
    assert_exit 1 $? "get of missing key returns 1"
}

test_help_subcommand_returns_0() {
    bash "$CLI" --help >/dev/null 2>&1
    assert_exit 0 $? "--help returns 0"
    bash "$CLI" help >/dev/null 2>&1
    assert_exit 0 $? "help returns 0"
}

test_unknown_subcommand_returns_2() {
    bash "$CLI" frobnicate >/dev/null 2>&1
    assert_exit 2 $? "unknown subcommand returns 2"
}

test_set_then_get_via_indirect_path() {
    bash -c "
        export STACKPILOT_KEYSTORE=file
        export STACKPILOT_KEYSTORE_FILE_DIR='$STACKPILOT_KEYSTORE_FILE_DIR'
        export STACKPILOT_KEYSTORE_FILE_ACK=1
        source '$REPO_ROOT/lib/keystore/core.sh'
        keystore_set cloudflare_api_token 'cli-test-value' >/dev/null
    "
    local g
    g=$(bash "$CLI" get cloudflare_api_token)
    assert_eq "cli-test-value" "$g" "CLI get reads what core set"
}

test_list_after_set() {
    local g
    g=$(bash "$CLI" list)
    case "$g" in
        *"cloudflare_api_token"*) PASS=$((PASS+1)) ;;
        *) FAIL=$((FAIL+1)); FAILED+=("list should contain cloudflare_api_token, got: $g") ;;
    esac
}

test_rm_by_name() {
    bash "$CLI" rm cloudflare_api_token >/dev/null
    bash "$CLI" get cloudflare_api_token >/dev/null 2>&1
    assert_exit 1 $? "after rm, get returns 1"
}

test_rm_by_provider_removes_all() {
    bash -c "
        export STACKPILOT_KEYSTORE=file
        export STACKPILOT_KEYSTORE_FILE_DIR='$STACKPILOT_KEYSTORE_FILE_DIR'
        export STACKPILOT_KEYSTORE_FILE_ACK=1
        source '$REPO_ROOT/lib/keystore/core.sh'
        keystore_set cloudflare_api_token v1 >/dev/null
        keystore_set cloudflare_account_id v2 >/dev/null
    "
    bash "$CLI" rm cloudflare >/dev/null
    bash "$CLI" get cloudflare_api_token >/dev/null 2>&1
    assert_exit 1 $? "rm provider removes api_token"
    bash "$CLI" get cloudflare_account_id >/dev/null 2>&1
    assert_exit 1 $? "rm provider removes account_id"
}

test_backend_subcommand
test_list_empty_initially
test_get_missing_returns_1
test_help_subcommand_returns_0
test_unknown_subcommand_returns_2
test_set_then_get_via_indirect_path
test_list_after_set
test_rm_by_name
test_rm_by_provider_removes_all

echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ $FAIL -gt 0 ]; then printf '  %s\n' "${FAILED[@]}"; exit 1; fi
