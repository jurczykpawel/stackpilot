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
# =============================================================================

test_detect_generic_no_markers() {
    (
        # No /klucz_api, no config, no SSH
        unset TOOLBOX_PROVIDER
        _ON_SERVER=false
        export _ON_SERVER
        # Don't let remote check run
        unset SSH_ALIAS

        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        detect_provider > /dev/null 2>&1
        load_provider_hooks > /dev/null 2>&1
        assert_eq "generic" "$TOOLBOX_PROVIDER" "detects generic when no markers"
    )
}

test_detect_config_override() {
    (
        unset TOOLBOX_PROVIDER
        _ON_SERVER=false
        export _ON_SERVER

        # Create temp config
        local TMPCONF
        TMPCONF=$(mktemp -d)
        mkdir -p "$TMPCONF/.config/stackpilot"
        echo "TOOLBOX_PROVIDER=mikrus" > "$TMPCONF/.config/stackpilot/config"
        export HOME="$TMPCONF"

        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        detect_provider > /dev/null 2>&1
        load_provider_hooks > /dev/null 2>&1
        assert_eq "mikrus" "$TOOLBOX_PROVIDER" "config override sets mikrus"
        rm -rf "$TMPCONF"
    )
}

test_generic_hooks_are_noop() {
    (
        unset TOOLBOX_PROVIDER
        _ON_SERVER=false
        export _ON_SERVER
        unset SSH_ALIAS

        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1

        # All hook functions should exist and be no-ops (return 0)
        provider_domain_options > /dev/null 2>&1
        assert_eq "0" "$?" "provider_domain_options exists (generic)"

        provider_db_options > /dev/null 2>&1
        assert_eq "0" "$?" "provider_db_options exists (generic)"

        provider_post_deploy > /dev/null 2>&1
        assert_eq "0" "$?" "provider_post_deploy exists (generic)"

        provider_upgrade_suggestion 0 > /dev/null 2>&1
        assert_eq "0" "$?" "provider_upgrade_suggestion exists (generic)"
    )
}

test_mikrus_hooks_load() {
    (
        unset TOOLBOX_PROVIDER
        _ON_SERVER=false
        export _ON_SERVER

        # Force mikrus via config
        local TMPCONF
        TMPCONF=$(mktemp -d)
        mkdir -p "$TMPCONF/.config/stackpilot"
        echo "TOOLBOX_PROVIDER=mikrus" > "$TMPCONF/.config/stackpilot/config"
        export HOME="$TMPCONF"

        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        detect_provider > /dev/null 2>&1
        load_provider_hooks > /dev/null 2>&1

        # Mikrus hooks should define real functions
        assert_true type provider_domain_options
        assert_true type provider_db_options
        assert_true type provider_post_deploy
        assert_true type provider_upgrade_suggestion
        assert_true type cytrus_register_domain
        assert_true type fetch_shared_db

        rm -rf "$TMPCONF"
    )
}

test_detect_already_set_skips() {
    (
        export TOOLBOX_PROVIDER="custom-provider"
        _ON_SERVER=false
        export _ON_SERVER

        # Should not re-detect if already set
        source "$REPO_ROOT/lib/providers/detect.sh" > /dev/null 2>&1
        assert_eq "custom-provider" "$TOOLBOX_PROVIDER" "does not re-detect if already set"
    )
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
