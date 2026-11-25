#!/bin/bash
set -e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"

child_message() {
    TOOLBOX_LANG="$1" bash -c '
        source "$1/lib/i18n.sh"
        bash -c '\''source "$1/lib/server-exec.sh"; msg "$MSG_DNS_CF_MODE"'\'' bash "$1"
    ' bash "$REPO_ROOT"
}
test_english_child_loads_message_variables() {
    assert_eq 'Cloudflare mode' "$(child_message en)" 'exported language and msg function do not carry locale variables'
}
test_polish_child_keeps_requested_language() {
    assert_eq 'Tryb Cloudflare' "$(child_message pl)"
}
test_explicit_language_in_fresh_shell_loads_messages() {
    local actual
    actual=$(TOOLBOX_LANG=pl bash -c 'source "$1/lib/server-exec.sh"; msg "$MSG_DNS_CF_MODE"' bash "$REPO_ROOT")
    assert_eq 'Tryb Cloudflare' "$actual"
}
test_same_process_keeps_loaded_messages() {
    local actual
    actual=$(TOOLBOX_LANG=pl bash -c '
        source "$1/lib/i18n.sh"
        MSG_DNS_CF_MODE="Already loaded"
        source "$1/lib/server-exec.sh"
        msg "$MSG_DNS_CF_MODE"
    ' bash "$REPO_ROOT")
    assert_eq 'Already loaded' "$actual" 'sourcing the library again keeps in-process configuration'
}
run_tests "$0"
