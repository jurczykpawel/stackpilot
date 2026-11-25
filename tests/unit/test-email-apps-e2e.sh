#!/bin/bash
set -e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"
ORIGINAL_PATH="$PATH"
setup() {
    TEST_TMPDIR=$(mktemp -d)
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/ssh" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_CALLS"
if [ "${SSH_RUN_RESERVATION:-}" = true ]; then
    remote_command="${2//\/opt\/stacks/$SERVER_STACKS}"
    PATH="$REMOTE_BIN:/usr/bin:/bin" /bin/bash -c "$remote_command"
else
    exit 1
fi
MOCK
    chmod +x "$TEST_TMPDIR/bin/ssh"
    export PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH" SSH_CALLS="$TEST_TMPDIR/ssh.calls"
    export E2E_RESULTS_DIR="$TEST_TMPDIR/results"
}
teardown() { PATH="$ORIGINAL_PATH"; rm -rf "$TEST_TMPDIR"; unset SSH_CALLS E2E_RESULTS_DIR SSH_RUN_RESERVATION SERVER_STACKS REMOTE_BIN E2E_CLEANUP DIG_CALLS; }
test_existing_stack_is_left_alone() {
    local code=0
    bash "$REPO_ROOT/tests/e2e/test-runner-e2e.sh" --suite=email-apps --ssh=test-host --app=notifuse > "$TEST_TMPDIR/output" 2>&1 || code=$?
    assert_eq 1 "$code"
    assert_contains "$(cat "$TEST_TMPDIR/output")" 'Refusing to use an existing stack'
    assert_not_contains "$(cat "$SSH_CALLS")" 'prune'
    assert_not_contains "$(cat "$SSH_CALLS")" 'compose down'
    assert_not_contains "$(cat "$SSH_CALLS")" 'rm -rf'
    assert_eq 1 "$(wc -l < "$SSH_CALLS" | tr -d ' ')" 'only the ownership reservation was attempted'
}
test_invalid_app_stops_before_ssh() {
    local code=0
    bash "$REPO_ROOT/tests/e2e/email-apps.sh" --ssh=test-host --app=unknown > "$TEST_TMPDIR/output" 2>&1 || code=$?
    assert_eq 2 "$code"
    assert_false test -f "$SSH_CALLS"
}
fresh_deploy_fixture() {
    mkdir -p "$TEST_TMPDIR/repo/tests/e2e" "$TEST_TMPDIR/repo/local" "$TEST_TMPDIR/remote-bin"
    cp "$REPO_ROOT/tests/e2e/email-apps.sh" "$TEST_TMPDIR/repo/tests/e2e/"
    cat > "$TEST_TMPDIR/repo/local/deploy.sh" <<'DEPLOY'
#!/bin/bash
printf 'deployment reached: %s\n' "$*"
exit 1
DEPLOY
    printf '#!/bin/bash\nexec "$@"\n' > "$TEST_TMPDIR/remote-bin/sudo"
    chmod +x "$TEST_TMPDIR/repo/local/deploy.sh" "$TEST_TMPDIR/remote-bin/sudo"
    export SSH_RUN_RESERVATION=true SERVER_STACKS="$TEST_TMPDIR/remote-stacks" REMOTE_BIN="$TEST_TMPDIR/remote-bin" E2E_CLEANUP=never
    local code=0
    bash "$TEST_TMPDIR/repo/tests/e2e/email-apps.sh" --ssh=test-host --app=notifuse "$@" > "$TEST_TMPDIR/output" 2>&1 || code=$?
    assert_eq 1 "$code" 'fake deploy deliberately stops before installing'
    assert_contains "$(cat "$TEST_TMPDIR/output")" 'deployment reached'
    assert_true test -f "$SERVER_STACKS/notifuse/.stackpilot-e2e-owner"
    assert_not_contains "$(cat "$TEST_TMPDIR/output")" 'command not found'
}
test_fresh_server_without_docker_reaches_deploy() { fresh_deploy_fixture; }
test_cloudflare_domain_is_passed_to_existing_deployer() {
    export DIG_CALLS="$TEST_TMPDIR/dig.calls"
    cat > "$TEST_TMPDIR/bin/dig" <<'DNS'
#!/bin/bash
printf '%s\n' "$*" >> "$DIG_CALLS"
DNS
    chmod +x "$TEST_TMPDIR/bin/dig"
    fresh_deploy_fixture --domain-type=cloudflare --domain-suffix=test.example.com
    assert_contains "$(cat "$TEST_TMPDIR/output")" 'notifuse --ssh=test-host --domain-type=cloudflare --domain=notifuse-test.example.com'
    assert_eq 3 "$(grep -c '^@1\.1\.1\.1 +short notifuse-test.example.com ' "$DIG_CALLS")" 'preflight bypasses the client resolver for every record type'
}
test_invalid_domain_options_stop_before_ssh() {
    local option code
    for option in '--domain-type=caddy' '--domain-type=cloudflare' '--domain-suffix=bad/host'; do
        code=0
        bash "$REPO_ROOT/tests/e2e/email-apps.sh" --ssh=test-host "$option" > "$TEST_TMPDIR/output" 2>&1 || code=$?
        assert_eq 2 "$code" "invalid domain option: $option"
        assert_false test -f "$SSH_CALLS"
    done
}
test_valid_cloudflare_options_reach_reservation() {
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/bin/dig"
    chmod +x "$TEST_TMPDIR/bin/dig"
    local code=0
    bash "$REPO_ROOT/tests/e2e/email-apps.sh" --ssh=test-host --app=notifuse --domain-type=cloudflare --domain-suffix=test.example.com > "$TEST_TMPDIR/output" 2>&1 || code=$?
    assert_eq 1 "$code"
    assert_contains "$(cat "$TEST_TMPDIR/output")" 'Refusing to use an existing stack'
}
run_tests "$0"
