#!/bin/bash

# Unit tests for sellf_ensure_required_secrets in apps/sellf/release-verify.sh
#
# This is the ONE place that generates the secrets/flags Sellf's production
# startup assertions require (admin-panel/src/lib/security/startup-assertions.ts).
# It is shared by apps/sellf/install.sh (PM2 + Docker) and apps/sellf/update.sh
# (PM2 + Docker) so a future required secret is added once, not per call site.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
LIB="$REPO_ROOT/apps/sellf/release-verify.sh"

source "$TESTS_DIR/test-runner.sh"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    # shellcheck source=../../apps/sellf/release-verify.sh
    source "$LIB"
}

teardown() {
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

env_with() {
    printf '%s\n' "$@" > "$TEST_TMPDIR/.env.local"
    echo "$TEST_TMPDIR/.env.local"
}

# =============================================================================
# Generates every required secret/flag when absent
# =============================================================================

test_generates_all_missing_secrets() {
    local env_file
    env_file=$(env_with "SUPABASE_URL=https://x.supabase.co")
    sellf_ensure_required_secrets "$env_file" > /dev/null

    assert_true grep -q "^APP_ENCRYPTION_KEY=" "$env_file"
    assert_true grep -q "^CHECKOUT_BINDING_SECRET=" "$env_file"
    assert_true grep -q "^LOGINWALL_SECRET=" "$env_file"
    assert_true grep -q "^CRON_SECRET=" "$env_file"
    assert_true grep -q "^ALTCHA_HMAC_KEY=" "$env_file"
    assert_true grep -q "^TRUSTED_PROXY=true$" "$env_file"
}

test_generated_values_are_non_empty_and_well_formed() {
    local env_file app_key checkout_secret loginwall_secret cron_secret altcha_key decoded_len
    env_file=$(env_with "SUPABASE_URL=https://x.supabase.co")
    sellf_ensure_required_secrets "$env_file" > /dev/null

    app_key=$(grep '^APP_ENCRYPTION_KEY=' "$env_file" | cut -d= -f2-)
    checkout_secret=$(grep '^CHECKOUT_BINDING_SECRET=' "$env_file" | cut -d= -f2-)
    loginwall_secret=$(grep '^LOGINWALL_SECRET=' "$env_file" | cut -d= -f2-)
    cron_secret=$(grep '^CRON_SECRET=' "$env_file" | cut -d= -f2-)
    altcha_key=$(grep '^ALTCHA_HMAC_KEY=' "$env_file" | cut -d= -f2-)

    # APP_ENCRYPTION_KEY must decode to exactly 32 bytes of base64
    # (matches assertAppEncryptionKey in startup-assertions.ts).
    decoded_len=$(printf '%s' "$app_key" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
    assert_eq "32" "$decoded_len" "APP_ENCRYPTION_KEY decodes to 32 bytes"

    # CHECKOUT_BINDING_SECRET must be at least 16 chars (assertCheckoutBindingSecret).
    assert_true test "${#checkout_secret}" -ge 16

    # LOGINWALL_SECRET / ALTCHA_HMAC_KEY are hex(32 bytes) = 64 lowercase hex chars.
    assert_eq "0" "$(printf '%s' "$loginwall_secret" | grep -cvE '^[0-9a-f]{64}$')" "LOGINWALL_SECRET is 64 lowercase hex chars"
    assert_eq "0" "$(printf '%s' "$altcha_key" | grep -cvE '^[0-9a-f]{64}$')" "ALTCHA_HMAC_KEY is 64 lowercase hex chars"

    assert_not_eq "" "$cron_secret" "CRON_SECRET is non-empty"
}

test_never_prints_a_generated_secret_value() {
    local env_file out app_key checkout_secret loginwall_secret cron_secret altcha_key
    env_file=$(env_with "SUPABASE_URL=https://x.supabase.co")
    out=$(sellf_ensure_required_secrets "$env_file" 2>&1)

    app_key=$(grep '^APP_ENCRYPTION_KEY=' "$env_file" | cut -d= -f2-)
    checkout_secret=$(grep '^CHECKOUT_BINDING_SECRET=' "$env_file" | cut -d= -f2-)
    loginwall_secret=$(grep '^LOGINWALL_SECRET=' "$env_file" | cut -d= -f2-)
    cron_secret=$(grep '^CRON_SECRET=' "$env_file" | cut -d= -f2-)
    altcha_key=$(grep '^ALTCHA_HMAC_KEY=' "$env_file" | cut -d= -f2-)

    assert_not_contains "$out" "$app_key" "stdout never echoes APP_ENCRYPTION_KEY's value"
    assert_not_contains "$out" "$checkout_secret" "stdout never echoes CHECKOUT_BINDING_SECRET's value"
    assert_not_contains "$out" "$loginwall_secret" "stdout never echoes LOGINWALL_SECRET's value"
    assert_not_contains "$out" "$cron_secret" "stdout never echoes CRON_SECRET's value"
    assert_not_contains "$out" "$altcha_key" "stdout never echoes ALTCHA_HMAC_KEY's value"
}

# =============================================================================
# Never overwrites an existing value
# =============================================================================

test_does_not_touch_existing_secrets() {
    local env_file
    env_file=$(env_with \
        "APP_ENCRYPTION_KEY=existing-app-key" \
        "CHECKOUT_BINDING_SECRET=existing-checkout-secret" \
        "LOGINWALL_SECRET=existing-loginwall-secret" \
        "CRON_SECRET=existing-cron-secret" \
        "ALTCHA_HMAC_KEY=existing-altcha-key" \
        "TRUSTED_PROXY=false")
    sellf_ensure_required_secrets "$env_file" > /dev/null

    assert_eq "1" "$(grep -c '^APP_ENCRYPTION_KEY=' "$env_file")" "APP_ENCRYPTION_KEY appears exactly once"
    assert_true grep -q "^APP_ENCRYPTION_KEY=existing-app-key$" "$env_file"
    assert_true grep -q "^CHECKOUT_BINDING_SECRET=existing-checkout-secret$" "$env_file"
    assert_true grep -q "^LOGINWALL_SECRET=existing-loginwall-secret$" "$env_file"
    assert_true grep -q "^CRON_SECRET=existing-cron-secret$" "$env_file"
    assert_true grep -q "^ALTCHA_HMAC_KEY=existing-altcha-key$" "$env_file"
    # An operator-set "false" is a deliberate choice — never flipped back to true.
    assert_true grep -q "^TRUSTED_PROXY=false$" "$env_file"
}

test_legacy_stripe_encryption_key_blocks_app_encryption_key() {
    local env_file
    env_file=$(env_with "STRIPE_ENCRYPTION_KEY=legacy-value")
    sellf_ensure_required_secrets "$env_file" > /dev/null

    assert_false grep -q "^APP_ENCRYPTION_KEY=" "$env_file"
    assert_true grep -q "^STRIPE_ENCRYPTION_KEY=legacy-value$" "$env_file"
}

test_turnstile_secret_blocks_altcha_generation() {
    local env_file
    env_file=$(env_with "CLOUDFLARE_TURNSTILE_SECRET_KEY=turnstile-value")
    sellf_ensure_required_secrets "$env_file" > /dev/null

    assert_false grep -q "^ALTCHA_HMAC_KEY=" "$env_file"
}

test_idempotent_second_call_makes_no_changes() {
    local env_file before after
    env_file=$(env_with "SUPABASE_URL=https://x.supabase.co")
    sellf_ensure_required_secrets "$env_file" > /dev/null
    before=$(cat "$env_file")
    sellf_ensure_required_secrets "$env_file" > /dev/null
    after=$(cat "$env_file")

    assert_eq "$before" "$after" "a second call changes nothing"
}

# =============================================================================
# Missing file
# =============================================================================

test_missing_env_file_fails_loudly() {
    local out rc
    out=$(sellf_ensure_required_secrets "$TEST_TMPDIR/does-not-exist.env" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "a missing env file is refused, not silently skipped"
    assert_contains "$out" "does-not-exist.env" "message names the missing file"
}

# =============================================================================
# Scripts actually call the shared function (both runtimes, both scripts)
# =============================================================================

test_update_docker_branch_calls_shared_secrets_function() {
    local section
    section=$(sed -n '/# ----- SELLF DOCKER UPDATE START -----/,/# ----- SELLF DOCKER UPDATE END -----/p' "$REPO_ROOT/apps/sellf/update.sh")
    assert_contains "$section" "sellf_ensure_required_secrets" \
        "update.sh's Docker branch ensures required secrets before starting the container"
}

test_update_docker_branch_ensures_secrets_before_starting_container() {
    local section ensure_line start_line
    section=$(sed -n '/# ----- SELLF DOCKER UPDATE START -----/,/# ----- SELLF DOCKER UPDATE END -----/p' "$REPO_ROOT/apps/sellf/update.sh")
    ensure_line=$(printf '%s\n' "$section" | grep -n 'sellf_ensure_required_secrets' | tail -1 | cut -d: -f1)
    start_line=$(printf '%s\n' "$section" | grep -n 'docker compose up -d' | tail -1 | cut -d: -f1)
    assert_not_eq "" "$ensure_line" "the ensure-secrets call is present"
    assert_not_eq "" "$start_line" "docker compose up -d is present"
    assert_true test "$ensure_line" -lt "$start_line"
}

test_update_pm2_path_calls_shared_secrets_function() {
    local before_docker_marker pm2_section
    # Everything after the Docker block's closing "fi" is the PM2/tarball path.
    pm2_section=$(sed -n '/# ----- SELLF DOCKER UPDATE END -----/,$p' "$REPO_ROOT/apps/sellf/update.sh")
    assert_contains "$pm2_section" "sellf_ensure_required_secrets" \
        "update.sh's PM2 path ensures required secrets"
}

test_install_calls_shared_secrets_function() {
    assert_contains "$(cat "$REPO_ROOT/apps/sellf/install.sh")" "sellf_ensure_required_secrets" \
        "install.sh ensures required secrets (covers both PM2 and Docker RUNTIME, shared code path)"
}

test_no_duplicated_inline_secret_generation_outside_shared_helper() {
    local hits
    hits=$(grep -nE '(APP_ENCRYPTION_KEY|CHECKOUT_BINDING_SECRET|LOGINWALL_SECRET|CRON_SECRET|ALTCHA_HMAC_KEY)=\$\(openssl rand' \
        "$REPO_ROOT/apps/sellf/install.sh" "$REPO_ROOT/apps/sellf/update.sh" || true)
    assert_eq "" "$hits" "install.sh/update.sh no longer generate these secrets inline — only release-verify.sh does"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
