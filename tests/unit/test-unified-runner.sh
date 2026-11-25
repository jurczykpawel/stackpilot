#!/bin/bash
set -e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"
setup() {
    TEST_TMPDIR=$(mktemp -d)
    mkdir -p "$TEST_TMPDIR/tests/e2e/results" "$TEST_TMPDIR/tests/unit"
    cp "$REPO_ROOT/tests/run.sh" "$TEST_TMPDIR/tests/"
    printf 'ok 1 - stale result\n' > "$TEST_TMPDIR/tests/e2e/results/results.tap"
    cat > "$TEST_TMPDIR/tests/e2e/test-runner-e2e.sh" <<'E2E'
#!/bin/bash
printf '%s\n' "$@" > "$ARG_LOG"
if [ -n "${FAKE_TAP:-}" ]; then
    mkdir -p "$E2E_RESULTS_DIR"
    printf '%s\n' "$FAKE_TAP" > "$E2E_RESULTS_DIR/results.tap"
fi
exit "${FAKE_EXIT:-0}"
E2E
    export E2E_RESULTS_DIR="$TEST_TMPDIR/custom-results" ARG_LOG="$TEST_TMPDIR/arguments"
}
teardown() { rm -rf "$TEST_TMPDIR"; unset E2E_RESULTS_DIR ARG_LOG FAKE_TAP FAKE_EXIT; }
run_fixture() {
    RESULT=0
    bash "$TEST_TMPDIR/tests/run.sh" e2e --ssh=fake-host "$@" > "$TEST_TMPDIR/output" 2>&1 || RESULT=$?
}
test_e2e_failure_without_tap_is_not_hidden_by_stale_results() {
    FAKE_EXIT=2 run_fixture
    assert_eq 1 "$RESULT"
    assert_contains "$(cat "$TEST_TMPDIR/output")" '1 failed'
}
test_tap_override_failure_changes_outer_exit() {
    FAKE_TAP=$'TAP version 13\nnot ok 1 - expected failure\n1..1' run_fixture
    assert_eq 1 "$RESULT"
    assert_contains "$(cat "$TEST_TMPDIR/output")" '1 failed'
}
test_successful_tap_and_passthrough() {
    FAKE_TAP=$'TAP version 13\nok 1 - expected success\n1..1' run_fixture --suite=email-apps --app=notifuse --domain-type=cloudflare --domain-suffix=test.example.com --cleanup=never
    assert_eq 0 "$RESULT"
    assert_contains "$(cat "$TEST_TMPDIR/output")" '1 passed'
    assert_true grep -qx -- '--domain-type=cloudflare' "$ARG_LOG"
    assert_true grep -qx -- '--domain-suffix=test.example.com' "$ARG_LOG"
    assert_true grep -qx -- '--cleanup=never' "$ARG_LOG"
}
test_unit_process_failure_without_assertion_output_fails_outer_runner() {
    printf '#!/bin/bash\nexit 2\n' > "$TEST_TMPDIR/tests/unit/test-process.sh"
    local code=0
    bash "$TEST_TMPDIR/tests/run.sh" unit > "$TEST_TMPDIR/output" 2>&1 || code=$?
    assert_eq 1 "$code"
}
test_hyphen_prefixed_assertion_pattern() {
    assert_contains 'deploy --domain-type=cloudflare' '--domain-type=cloudflare'
    assert_not_contains 'deploy --domain-type=cloudflare' '--cleanup=never'
}
test_nonzero_exit_with_passing_tap_still_fails() {
    FAKE_EXIT=2 FAKE_TAP=$'TAP version 13\nok 1 - completed assertion\n1..1' run_fixture
    assert_eq 1 "$RESULT"
}
test_incomplete_tap_fails_even_with_zero_exit() {
    FAKE_TAP=$'TAP version 13\nok 1 - completed assertion' run_fixture
    assert_eq 1 "$RESULT"
}
test_e2e_config_preserves_results_override() {
    local actual
    actual=$(bash -c 'source "$1"; printf "%s" "$E2E_RESULTS_DIR"' bash "$REPO_ROOT/tests/e2e/config.sh")
    assert_eq "$E2E_RESULTS_DIR" "$actual"
}
run_tests "$0"
