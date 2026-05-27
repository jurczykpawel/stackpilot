# shellcheck shell=bash
# Asserts that a wizard implements all required functions.
# Usage: source wizard file first, then call wizard_assert_contract_or_die.

wizard_assert_contract_or_die() {
    local provider="${1:-unknown}"
    local missing=""
    local f
    for f in wizard_required_keys wizard_check wizard_validate wizard_run; do
        if ! declare -F "$f" >/dev/null 2>&1; then
            missing="$missing $f"
        fi
    done
    if [ -n "$missing" ]; then
        echo "wizard $provider: missing required functions:$missing" >&2
        return 1
    fi
    return 0
}
