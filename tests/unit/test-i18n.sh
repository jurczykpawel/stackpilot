#!/bin/bash

# Tests for lib/i18n.sh

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

# =============================================================================
# i18n loading tests
# Each test sources i18n.sh in a subshell to isolate TOOLBOX_LANG side-effects.
# The subshell exits non-zero on any assertion failure, which the runner catches
# via test_exit (the function's return value propagates from the subshell).
# =============================================================================

test_i18n_loads_en() {
    local toolbox_lang msg_hc
    toolbox_lang=$(
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/i18n.sh"
        echo "$TOOLBOX_LANG"
    )
    msg_hc=$(
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/i18n.sh"
        echo "${MSG_HC_CHECKING:-}"
    )
    assert_eq "en" "$toolbox_lang" "TOOLBOX_LANG set to en"
    assert_not_eq "" "$msg_hc" "EN string MSG_HC_CHECKING loaded"
}

test_i18n_loads_pl() {
    local toolbox_lang msg_hc
    toolbox_lang=$(
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=pl
        source "$REPO_ROOT/lib/i18n.sh"
        echo "$TOOLBOX_LANG"
    )
    msg_hc=$(
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=pl
        source "$REPO_ROOT/lib/i18n.sh"
        echo "${MSG_HC_CHECKING:-}"
    )
    assert_eq "pl" "$toolbox_lang" "TOOLBOX_LANG set to pl"
    assert_not_eq "" "$msg_hc" "PL string MSG_HC_CHECKING loaded"
}

test_i18n_fallback_unknown_locale() {
    local output toolbox_lang
    output=$(
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=xx
        source "$REPO_ROOT/lib/i18n.sh" 2>&1
        echo "__LANG__${TOOLBOX_LANG}"
    )
    toolbox_lang=$(echo "$output" | grep -o '__LANG__.*' | sed 's/__LANG__//')
    local warning
    warning=$(echo "$output" | grep -v '__LANG__')
    assert_contains "$warning" "xx" "warns about missing locale"
    assert_eq "xx" "$toolbox_lang" "TOOLBOX_LANG stays as requested"
}

test_msg_basic() {
    local output
    output=$(
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/i18n.sh"
        msg "hello %s" "world"
    )
    assert_eq "hello world" "$output" "msg() formats with printf"
}

test_msg_no_args() {
    local output
    output=$(
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/i18n.sh"
        msg "plain message"
    )
    assert_eq "plain message" "$output" "msg() works without args"
}

test_msg_n_no_newline() {
    local output
    output=$(
        unset TOOLBOX_LANG
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/i18n.sh"
        msg_n "no newline %s" "here"; echo "END"
    )
    assert_contains "$output" "no newline hereEND" "msg_n has no trailing newline"
}

test_i18n_en_has_all_expected_prefixes() {
    local hc cp dbs bc prov
    hc=$(unset TOOLBOX_LANG; export TOOLBOX_LANG=en; source "$REPO_ROOT/lib/i18n.sh"; echo "${MSG_HC_CHECKING:-}")
    cp=$(unset TOOLBOX_LANG; export TOOLBOX_LANG=en; source "$REPO_ROOT/lib/i18n.sh"; echo "${MSG_CP_UNKNOWN_OPTION:-}")
    dbs=$(unset TOOLBOX_LANG; export TOOLBOX_LANG=en; source "$REPO_ROOT/lib/i18n.sh"; echo "${MSG_DBS_HEADER:-}")
    bc=$(unset TOOLBOX_LANG; export TOOLBOX_LANG=en; source "$REPO_ROOT/lib/i18n.sh"; echo "${MSG_BC_START:-}")
    prov=$(unset TOOLBOX_LANG; export TOOLBOX_LANG=en; source "$REPO_ROOT/lib/i18n.sh"; echo "${MSG_PROV_DETECTED:-}")
    assert_not_eq "" "$hc"   "MSG_HC_ exists"
    assert_not_eq "" "$cp"   "MSG_CP_ exists"
    assert_not_eq "" "$dbs"  "MSG_DBS_ exists"
    assert_not_eq "" "$bc"   "MSG_BC_ exists"
    assert_not_eq "" "$prov" "MSG_PROV_ exists"
}

test_i18n_config_file_lang() {
    local toolbox_lang
    toolbox_lang=$(
        local TMPCONF
        TMPCONF=$(mktemp -d)
        mkdir -p "$TMPCONF/.config/stackpilot"
        echo "lang=pl" > "$TMPCONF/.config/stackpilot/config"
        unset TOOLBOX_LANG
        export HOME="$TMPCONF"
        source "$REPO_ROOT/lib/i18n.sh"
        echo "$TOOLBOX_LANG"
        rm -rf "$TMPCONF"
    )
    assert_eq "pl" "$toolbox_lang" "config file sets language"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
