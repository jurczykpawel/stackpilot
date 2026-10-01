#!/bin/bash

# Unit tests for lib/sellf-setup.sh — GoTrue email template wiring for
# self-hosted Supabase.
#
# Sellf's login is a magic link; /auth/callback requires the link to carry
# token_hash, which GoTrue's default templates do not include. The Cloud
# path (configure_supabase_settings, Management API) already sets this up.
# This file covers the two self-hosted cases:
#   - SUPABASE_MODE=local, Supabase deployed by stackpilot itself
#     (apps/supabase/install.sh, same server) -> wire GoTrue's env vars
#     directly and recreate the auth container.
#   - Any other self-hosted Supabase (BYO, Coolify's own, etc.) -> stackpilot
#     cannot reach its .env, so print copy-pasteable instructions instead.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
LIB="$REPO_ROOT/lib/sellf-setup.sh"

source "$TESTS_DIR/test-runner.sh"

# Load i18n (sellf-setup.sh depends on msg() + MSG_* keys)
export TOOLBOX_LANG=en
source "$REPO_ROOT/lib/i18n.sh"

# =============================================================================
# ssh() SPY/MOCK
#
# Every ssh call is logged verbatim (arg 2, the remote command) to SSH_LOG so
# tests can assert on what would have been sent to the server, without a real
# server. Behavior per call is controlled by the SSH_* globals below.
# =============================================================================

SSH_LOG=""
SSH_MANAGED=true          # response to the "is this a stackpilot-managed stack" probe
SSH_CURRENT_ALLOW_LIST=""  # canned response to the GOTRUE_URI_ALLOW_LIST grep
SSH_FAIL_ENV_SCRIPT=false  # force the env-writing command to fail
SSH_FAIL_RESTART=false     # force the auth-container recreate command to fail

ssh() {
    local _alias="$1"
    local cmd="$2"
    printf '%s\n' "$cmd" >> "$SSH_LOG"

    case "$cmd" in
        *"test -f"*)
            [ "$SSH_MANAGED" = true ]
            return $?
            ;;
        *"GOTRUE_URI_ALLOW_LIST"*"grep"*|*grep*"GOTRUE_URI_ALLOW_LIST"*)
            printf '%s' "$SSH_CURRENT_ALLOW_LIST"
            return 0
            ;;
        *"docker compose up -d --force-recreate auth"*)
            [ "$SSH_FAIL_RESTART" != true ]
            return $?
            ;;
        *)
            [ "$SSH_FAIL_ENV_SCRIPT" != true ]
            return $?
            ;;
    esac
}
export -f ssh

setup() {
    TEST_TMPDIR=$(mktemp -d)
    SSH_LOG="$TEST_TMPDIR/ssh.log"
    : > "$SSH_LOG"
    SSH_MANAGED=true
    SSH_CURRENT_ALLOW_LIST=""
    SSH_FAIL_ENV_SCRIPT=false
    SSH_FAIL_RESTART=false
    SELLF_LOCAL_SUPABASE_STACK_DIR="/opt/stacks/supabase"
    unset SUPABASE_TOKEN PROJECT_REF SUPABASE_URL SUPABASE_MODE
    # shellcheck source=../../lib/sellf-setup.sh
    source "$LIB"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

ssh_log_contains() {
    grep -qF "$1" "$SSH_LOG"
}

# =============================================================================
# sellf_configure_local_gotrue_templates — managed self-hosted stack
# =============================================================================

test_writes_all_five_template_urls_with_the_sellf_domain() {
    sellf_configure_local_gotrue_templates "shop.example.com" "vps" > /dev/null

    assert_true ssh_log_contains "GOTRUE_MAILER_TEMPLATES_MAGIC_LINK=https://shop.example.com/auth-email-templates/magic-link.html"
    assert_true ssh_log_contains "GOTRUE_MAILER_TEMPLATES_CONFIRMATION=https://shop.example.com/auth-email-templates/confirmation.html"
    assert_true ssh_log_contains "GOTRUE_MAILER_TEMPLATES_RECOVERY=https://shop.example.com/auth-email-templates/recovery.html"
    assert_true ssh_log_contains "GOTRUE_MAILER_TEMPLATES_INVITE=https://shop.example.com/auth-email-templates/invite.html"
    assert_true ssh_log_contains "GOTRUE_MAILER_TEMPLATES_EMAIL_CHANGE=https://shop.example.com/auth-email-templates/email-change.html"
}

test_writes_subjects_for_all_five_flows() {
    sellf_configure_local_gotrue_templates "shop.example.com" "vps" > /dev/null

    assert_true ssh_log_contains "GOTRUE_MAILER_SUBJECTS_MAGIC_LINK=$MSG_SELLF_EMAIL_MAGIC_LINK"
    assert_true ssh_log_contains "GOTRUE_MAILER_SUBJECTS_CONFIRMATION=$MSG_SELLF_EMAIL_CONFIRMATION"
    assert_true ssh_log_contains "GOTRUE_MAILER_SUBJECTS_RECOVERY=$MSG_SELLF_EMAIL_RECOVERY"
    assert_true ssh_log_contains "GOTRUE_MAILER_SUBJECTS_INVITE=$MSG_SELLF_EMAIL_INVITE"
    assert_true ssh_log_contains "GOTRUE_MAILER_SUBJECTS_EMAIL_CHANGE=$MSG_SELLF_EMAIL_CHANGE"
}

test_sets_uri_allow_list_when_none_exists() {
    SSH_CURRENT_ALLOW_LIST=""
    sellf_configure_local_gotrue_templates "shop.example.com" "vps" > /dev/null

    assert_true ssh_log_contains "GOTRUE_URI_ALLOW_LIST=https://shop.example.com/*"
}

test_merges_uri_allow_list_with_existing_value() {
    SSH_CURRENT_ALLOW_LIST="https://other.example.com/*"
    sellf_configure_local_gotrue_templates "shop.example.com" "vps" > /dev/null

    assert_true ssh_log_contains "GOTRUE_URI_ALLOW_LIST=https://other.example.com/*,https://shop.example.com/*"
}

test_does_not_duplicate_uri_allow_list_entry_already_present() {
    SSH_CURRENT_ALLOW_LIST="https://other.example.com/*,https://shop.example.com/*"
    sellf_configure_local_gotrue_templates "shop.example.com" "vps" > /dev/null

    assert_true ssh_log_contains "GOTRUE_URI_ALLOW_LIST=https://other.example.com/*,https://shop.example.com/*"
    assert_false ssh_log_contains "https://shop.example.com/*,https://shop.example.com/*"
}

test_recreates_the_auth_container_after_writing_env() {
    sellf_configure_local_gotrue_templates "shop.example.com" "vps" > /dev/null

    assert_true ssh_log_contains "cd '/opt/stacks/supabase'"
    assert_true ssh_log_contains "docker compose up -d --force-recreate auth"
}

test_returns_success_when_everything_worked() {
    assert_exit_code 0 sellf_configure_local_gotrue_templates "shop.example.com" "vps"
}

test_returns_failure_when_env_write_fails() {
    SSH_FAIL_ENV_SCRIPT=true
    assert_exit_code 1 sellf_configure_local_gotrue_templates "shop.example.com" "vps"
}

test_returns_failure_when_container_restart_fails() {
    SSH_FAIL_RESTART=true
    assert_exit_code 1 sellf_configure_local_gotrue_templates "shop.example.com" "vps"
}

# =============================================================================
# sellf_configure_local_gotrue_templates — no public domain yet
# =============================================================================

test_refuses_when_domain_is_empty() {
    assert_exit_code 1 sellf_configure_local_gotrue_templates "" "vps"
    assert_eq "" "$(cat "$SSH_LOG")" "no ssh calls should happen without a domain"
}

test_refuses_when_domain_is_the_placeholder_dash() {
    assert_exit_code 1 sellf_configure_local_gotrue_templates "-" "vps"
    assert_eq "" "$(cat "$SSH_LOG")" "no ssh calls should happen with the '-' placeholder domain"
}

# =============================================================================
# sellf_configure_local_gotrue_templates — SUPABASE_MODE=local but the stack
# was NOT deployed by stackpilot itself (unexpected, but must degrade safely)
# =============================================================================

test_falls_back_to_instructions_when_stack_is_not_managed() {
    SSH_MANAGED=false
    local output result
    output=$(sellf_configure_local_gotrue_templates "shop.example.com" "vps") && result=0 || result=$?

    assert_eq "1" "$result"
    assert_contains "$output" "GOTRUE_MAILER_TEMPLATES_MAGIC_LINK=https://shop.example.com/auth-email-templates/magic-link.html"
    assert_contains "$output" "GOTRUE_URI_ALLOW_LIST=https://shop.example.com/*"
    # Only the probe call should have been made — never write to a stack we don't manage
    assert_eq "1" "$(wc -l < "$SSH_LOG" | tr -d '[:space:]')"
}

# =============================================================================
# sellf_show_unmanaged_gotrue_instructions — printed for BYO self-hosted Supabase
# =============================================================================

test_unmanaged_instructions_list_all_five_template_urls() {
    local output
    output=$(sellf_show_unmanaged_gotrue_instructions "shop.example.com")

    assert_contains "$output" "GOTRUE_MAILER_TEMPLATES_MAGIC_LINK=https://shop.example.com/auth-email-templates/magic-link.html"
    assert_contains "$output" "GOTRUE_MAILER_TEMPLATES_CONFIRMATION=https://shop.example.com/auth-email-templates/confirmation.html"
    assert_contains "$output" "GOTRUE_MAILER_TEMPLATES_RECOVERY=https://shop.example.com/auth-email-templates/recovery.html"
    assert_contains "$output" "GOTRUE_MAILER_TEMPLATES_INVITE=https://shop.example.com/auth-email-templates/invite.html"
    assert_contains "$output" "GOTRUE_MAILER_TEMPLATES_EMAIL_CHANGE=https://shop.example.com/auth-email-templates/email-change.html"
    assert_contains "$output" "GOTRUE_URI_ALLOW_LIST=https://shop.example.com/*"
}

test_unmanaged_instructions_make_no_network_calls() {
    sellf_show_unmanaged_gotrue_instructions "shop.example.com" > /dev/null
    assert_eq "" "$(cat "$SSH_LOG")"
}

# =============================================================================
# sellf_configure_supabase_post_install — dispatcher
# =============================================================================

test_dispatcher_uses_cloud_management_api_when_token_and_project_ref_are_set() {
    SUPABASE_TOKEN="tok"
    PROJECT_REF="abcdefgh"
    # Stub out the Cloud path so this test only proves routing, not its own behavior
    # (configure_supabase_settings is exercised by its own existing call sites).
    configure_supabase_settings() { echo "CLOUD_PATH_CALLED:$1:$3"; return 0; }

    local output
    output=$(sellf_configure_supabase_post_install "shop.example.com" "" "vps")

    assert_contains "$output" "CLOUD_PATH_CALLED:shop.example.com:vps"
    assert_eq "" "$(cat "$SSH_LOG")" "cloud path must not touch ssh directly"
}

test_dispatcher_uses_local_gotrue_wiring_when_mode_is_local() {
    SUPABASE_MODE="local"

    sellf_configure_supabase_post_install "shop.example.com" "" "vps" > /dev/null

    assert_true ssh_log_contains "GOTRUE_MAILER_TEMPLATES_MAGIC_LINK=https://shop.example.com/auth-email-templates/magic-link.html"
}

test_dispatcher_prints_instructions_for_unmanaged_self_hosted_url() {
    SUPABASE_MODE="cloud"
    SUPABASE_URL="https://supabase.my-own-vps.example.com"

    local output result
    output=$(sellf_configure_supabase_post_install "shop.example.com" "" "vps") && result=0 || result=$?

    assert_eq "1" "$result"
    assert_contains "$output" "GOTRUE_MAILER_TEMPLATES_MAGIC_LINK=https://shop.example.com/auth-email-templates/magic-link.html"
    assert_eq "" "$(cat "$SSH_LOG")" "unmanaged instructions must not touch ssh"
}

test_dispatcher_is_a_silent_noop_for_plain_cloud_url_without_a_token() {
    # Pre-existing Cloud behavior (e.g. a cached deploy-config.env without a
    # fresh Management API token): must stay a silent no-op, not get
    # mis-detected as an unmanaged self-hosted Supabase.
    SUPABASE_MODE="cloud"
    SUPABASE_URL="https://abcdefgh.supabase.co"

    assert_exit_code 0 sellf_configure_supabase_post_install "shop.example.com" "" "vps"
    assert_eq "" "$(cat "$SSH_LOG")"
}

run_tests
