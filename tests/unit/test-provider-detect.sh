#!/bin/bash

# Tests for lib/providers/detect.sh

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

# Load i18n
export TOOLBOX_LANG=en
source "$REPO_ROOT/lib/i18n.sh"

# =============================================================================
# detect_provider tests
# Each test runs in a subshell to isolate TOOLBOX_PROVIDER / HOME side-effects.
# Values needed for assertions are captured via stdout before the subshell exits.
# =============================================================================

test_detect_generic_no_markers() {
    local provider
    provider=$(
        unset TOOLBOX_PROVIDER
        _ON_SERVER=false; export _ON_SERVER
        unset SSH_ALIAS
        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        detect_provider > /dev/null 2>&1
        load_provider_hooks > /dev/null 2>&1
        echo "$TOOLBOX_PROVIDER"
    )
    assert_eq "generic" "$provider" "detects generic when no markers"
}

test_detect_config_override() {
    local provider
    provider=$(
        unset TOOLBOX_PROVIDER
        _ON_SERVER=false; export _ON_SERVER
        local TMPCONF
        TMPCONF=$(mktemp -d)
        mkdir -p "$TMPCONF/.config/stackpilot"
        echo "TOOLBOX_PROVIDER=mikrus" > "$TMPCONF/.config/stackpilot/config"
        export HOME="$TMPCONF"
        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        detect_provider > /dev/null 2>&1
        load_provider_hooks > /dev/null 2>&1
        echo "$TOOLBOX_PROVIDER"
        rm -rf "$TMPCONF"
    )
    assert_eq "mikrus" "$provider" "config override sets mikrus"
}

test_generic_hooks_are_noop() {
    local rc_domain rc_db rc_post rc_upgrade
    # Run hooks in subshell, capture each exit code separately via stdout
    rc_domain=$(
        unset TOOLBOX_PROVIDER; _ON_SERVER=false; export _ON_SERVER; unset SSH_ALIAS
        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        provider_domain_options > /dev/null 2>&1; echo $?
    )
    rc_db=$(
        unset TOOLBOX_PROVIDER; _ON_SERVER=false; export _ON_SERVER; unset SSH_ALIAS
        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        provider_db_options > /dev/null 2>&1; echo $?
    )
    rc_post=$(
        unset TOOLBOX_PROVIDER; _ON_SERVER=false; export _ON_SERVER; unset SSH_ALIAS
        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        provider_post_deploy > /dev/null 2>&1; echo $?
    )
    rc_upgrade=$(
        unset TOOLBOX_PROVIDER; _ON_SERVER=false; export _ON_SERVER; unset SSH_ALIAS
        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        provider_upgrade_suggestion 0 > /dev/null 2>&1; echo $?
    )
    assert_eq "0" "$rc_domain"  "provider_domain_options is noop (generic)"
    assert_eq "0" "$rc_db"      "provider_db_options is noop (generic)"
    assert_eq "0" "$rc_post"    "provider_post_deploy is noop (generic)"
    assert_eq "0" "$rc_upgrade" "provider_upgrade_suggestion is noop (generic)"
}

test_mikrus_hooks_load() {
    local has_domain has_db has_post has_upgrade has_cytrus has_fetchdb
    local TMPCONF
    TMPCONF=$(mktemp -d)
    mkdir -p "$TMPCONF/.config/stackpilot"
    echo "TOOLBOX_PROVIDER=mikrus" > "$TMPCONF/.config/stackpilot/config"

    _load_and_check() {
        export HOME="$TMPCONF"
        unset TOOLBOX_PROVIDER; _ON_SERVER=false; export _ON_SERVER
        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        detect_provider > /dev/null 2>&1
        load_provider_hooks > /dev/null 2>&1
        type "$1" > /dev/null 2>&1 && echo "yes" || echo "no"
    }

    has_domain=$(  _load_and_check provider_domain_options)
    has_db=$(      _load_and_check provider_db_options)
    has_post=$(    _load_and_check provider_post_deploy)
    has_upgrade=$( _load_and_check provider_upgrade_suggestion)
    has_cytrus=$(  _load_and_check cytrus_register_domain)
    has_fetchdb=$( _load_and_check fetch_shared_db)

    rm -rf "$TMPCONF"
    unset -f _load_and_check

    assert_eq "yes" "$has_domain"  "provider_domain_options defined (mikrus)"
    assert_eq "yes" "$has_db"      "provider_db_options defined (mikrus)"
    assert_eq "yes" "$has_post"    "provider_post_deploy defined (mikrus)"
    assert_eq "yes" "$has_upgrade" "provider_upgrade_suggestion defined (mikrus)"
    assert_eq "yes" "$has_cytrus"  "cytrus_register_domain defined (mikrus)"
    assert_eq "yes" "$has_fetchdb" "fetch_shared_db defined (mikrus)"
}

test_detect_already_set_skips() {
    local provider
    provider=$(
        export TOOLBOX_PROVIDER="custom-provider"
        _ON_SERVER=false; export _ON_SERVER
        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        echo "$TOOLBOX_PROVIDER"
    )
    assert_eq "custom-provider" "$provider" "does not re-detect if already set"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
