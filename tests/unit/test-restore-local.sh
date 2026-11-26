#!/bin/bash

# StackPilot - Unit tests for local/restore.sh (interactive restic restore)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/test-runner.sh"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    T=$TEST_TMPDIR
    mkdir -p "$T/bin"
    : > "$T/argv"
    # shellcheck disable=SC2016
    cat > "$T/bin/ssh" <<'STUB'
#!/bin/bash
[ "$1" = -G ] && { echo "hostname 203.0.113.7"; echo "user root"; exit 0; }
printf '%s\n' "$*" >> "$T/argv"
case "$*" in
    *"id -u"*) echo 0 ;;
    *"cat >"*) cat > /dev/null ;;
    *snapshots*) [ -n "${NO_CONFIG:-}" ] && exit 1; echo "ID        Time                 Host"; echo "1a2b3c4d  2026-11-25 03:00:01  srv1" ;;
esac
exit 0
STUB
    chmod +x "$T/bin/ssh"
    export T PATH="$T/bin:$PATH" TOOLBOX_LANG=en
    unset NO_CONFIG
}

restore() { # args then answers
    local ARGS=()
    while [ "$1" != -- ]; do ARGS+=("$1"); shift; done
    shift
    printf '%s\n' "$@" | bash "$REPO_ROOT/local/restore.sh" "${ARGS[@]}" > "$T/out" 2>&1
}

test_restores_chosen_snapshot_and_app_after_confirmation() {
    restore vps -- 1a2b3c4d umami YES
    assert_eq "0" "$?" "restore succeeds" || cat "$T/out"
    assert_contains "$(cat "$T/argv")" "stackpilot-backup restore 1a2b3c4d umami --yes" "engine called"
    assert_contains "$(cat "$T/out")" "1a2b3c4d  2026-11-25" "snapshots listed"
}

test_defaults_to_latest_and_everything() {
    restore vps -- "" "" TAK
    assert_eq "0" "$?" "restore succeeds" || cat "$T/out"
    assert_contains "$(cat "$T/argv")" "stackpilot-backup restore latest --yes" "full restore of latest"
}

test_app_argument_skips_question() {
    restore vps n8n -- latest YES
    assert_contains "$(cat "$T/argv")" "stackpilot-backup restore latest n8n --yes" "app from argument"
}

test_wrong_confirmation_aborts() {
    restore vps -- latest umami yes
    assert_not_eq "0" "$?" "lowercase yes is not enough"
    assert_not_contains "$(cat "$T/argv")" "restore latest" "engine not called"
}

test_rejects_unsafe_input() {
    restore vps -- "latest;reboot" "" YES
    assert_not_eq "0" "$?" "invalid snapshot rejected"
    restore vps -- latest "../etc" YES
    assert_not_eq "0" "$?" "invalid app rejected"
    assert_not_contains "$(cat "$T/argv")" "--yes" "engine not called"
}

test_missing_configuration_stops_early() {
    NO_CONFIG=1 restore vps -- latest umami YES
    assert_not_eq "0" "$?" "fails without configuration"
    assert_contains "$(cat "$T/out")" "setup-backup.sh" "points to the wizard"
    assert_not_contains "$(cat "$T/argv")" "--yes" "engine not called"
}

run_tests "$0"
