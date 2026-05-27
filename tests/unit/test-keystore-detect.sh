#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0; FAILED=()
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected='$1' actual='$2')"); fi; }
assert_exit() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$3 (expected_exit=$1 actual=$2)"); fi; }

test_env_override_to_file() {
    local got
    got=$(
        export STACKPILOT_KEYSTORE=file
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/keystore/detect.sh"
        keystore_detect_backend
    )
    assert_eq "file" "$got" "env override picks file"
}

test_auto_pick_on_current_platform() {
    local got
    got=$(
        unset STACKPILOT_KEYSTORE
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/keystore/detect.sh"
        keystore_detect_backend
    )
    case "$got" in
        keychain|libsecret|file) PASS=$((PASS+1)) ;;
        *) FAIL=$((FAIL+1)); FAILED+=("auto-pick returned unexpected: '$got'") ;;
    esac
}

test_error_on_unknown_override() {
    (
        export STACKPILOT_KEYSTORE=nonexistent_backend
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/keystore/detect.sh"
        keystore_detect_backend
    ) >/dev/null 2>&1
    assert_exit 1 $? "unknown backend override returns 1"
}

test_env_override_to_keychain_on_darwin() {
    if [ "$(uname -s)" != "Darwin" ]; then
        PASS=$((PASS+1))
        return
    fi
    local got
    got=$(
        export STACKPILOT_KEYSTORE=keychain
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/keystore/detect.sh"
        keystore_detect_backend
    )
    assert_eq "keychain" "$got" "env override picks keychain on macOS"
}

test_env_override_to_file
test_auto_pick_on_current_platform
test_error_on_unknown_override
test_env_override_to_keychain_on_darwin

echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ $FAIL -gt 0 ]; then printf '  %s\n' "${FAILED[@]}"; exit 1; fi
