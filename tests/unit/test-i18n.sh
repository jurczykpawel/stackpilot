#!/bin/bash

# Tests for lib/i18n.sh

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

# =============================================================================
# i18n loading tests
# =============================================================================

test_i18n_loads_en() {
    (
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/i18n.sh"
        assert_eq "en" "$TOOLBOX_LANG" "TOOLBOX_LANG set to en"
        assert_not_eq "" "$MSG_HC_CHECKING" "EN string loaded"
    )
}

test_i18n_loads_pl() {
    (
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=pl
        source "$REPO_ROOT/lib/i18n.sh"
        assert_eq "pl" "$TOOLBOX_LANG" "TOOLBOX_LANG set to pl"
        # PL strings should differ from EN
        assert_not_eq "" "$MSG_HC_CHECKING" "PL string loaded"
    )
}

test_i18n_fallback_unknown_locale() {
    (
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=xx
        # Should warn about missing locale but fall back to EN
        local output
        output=$(source "$REPO_ROOT/lib/i18n.sh" 2>&1)
        assert_contains "$output" "xx" "warns about missing locale"
        assert_eq "xx" "$TOOLBOX_LANG" "TOOLBOX_LANG stays as requested"
    )
}

test_msg_basic() {
    (
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/i18n.sh"
        local output
        output=$(msg "hello %s" "world")
        assert_eq "hello world" "$output" "msg() formats with printf"
    )
}

test_msg_no_args() {
    (
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/i18n.sh"
        local output
        output=$(msg "plain message")
        assert_eq "plain message" "$output" "msg() works without args"
    )
}

test_msg_n_no_newline() {
    (
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/i18n.sh"
        # msg_n should not add newline — test by checking raw output
        local output
        output=$(msg_n "no newline %s" "here"; echo "END")
        assert_contains "$output" "no newline hereEND" "msg_n has no trailing newline"
    )
}

test_i18n_en_has_all_expected_prefixes() {
    (
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/i18n.sh"
        # Spot check several key prefixes
        assert_not_eq "" "${MSG_HC_CHECKING:-}" "MSG_HC_ exists"
        assert_not_eq "" "${MSG_CP_UNKNOWN_OPTION:-}" "MSG_CP_ exists"
        assert_not_eq "" "${MSG_DBS_HEADER:-}" "MSG_DBS_ exists"
        assert_not_eq "" "${MSG_BC_START:-}" "MSG_BC_ exists"
        assert_not_eq "" "${MSG_PROV_DETECTED:-}" "MSG_PROV_ exists"
    )
}

test_i18n_config_file_lang() {
    (
        # Test that config file can set language
        local TMPCONF
        TMPCONF=$(mktemp -d)
        mkdir -p "$TMPCONF"
        echo "lang=pl" > "$TMPCONF/config"
        unset TOOLBOX_LANG
        export HOME="$TMPCONF"
        mkdir -p "$TMPCONF/.config/stackpilot"
        echo "lang=pl" > "$TMPCONF/.config/stackpilot/config"
        source "$REPO_ROOT/lib/i18n.sh"
        assert_eq "pl" "$TOOLBOX_LANG" "config file sets language"
        rm -rf "$TMPCONF"
    )
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
