#!/bin/bash

# ensure_toolbox (lib/server-exec.sh): copies this checkout with rsync and falls
# back to the git-based bootstrap on the server when rsync fails.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

ORIGINAL_PATH="$PATH"

# ssh stands for the server: deploy.sh appears once rsync or the bootstrap ran.
setup() {
    TEST_TMPDIR=$(mktemp -d)
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/ssh" <<EOF
#!/bin/bash
alias="\$1"; shift
cmd="\$*"
echo "\$cmd" >> "$TEST_TMPDIR/ssh.log"
case "\$cmd" in
    "test -f /opt/stackpilot/local/deploy.sh") [ -e "$TEST_TMPDIR/installed" ] ;;
    *"bash -s"*) cat > "$TEST_TMPDIR/bootstrap-input"; touch "$TEST_TMPDIR/installed" ;;
    *) exit 0 ;;
esac
EOF
    cat > "$TEST_TMPDIR/bin/rsync" <<EOF
#!/bin/bash
echo "rsync \$*" >> "$TEST_TMPDIR/rsync.log"
[ "\$RSYNC_RESULT" = ok ] || { echo "bash: line 1: rsync: command not found" >&2; exit 12; }
touch "$TEST_TMPDIR/installed"
EOF
    chmod +x "$TEST_TMPDIR/bin/"*
    export PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
}

teardown() {
    export PATH="$ORIGINAL_PATH"
    rm -rf "$TEST_TMPDIR"
}

run_ensure_toolbox() {
    (
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/server-exec.sh"
        _ON_SERVER=false
        ensure_toolbox vps
    ) > "$TEST_TMPDIR/out" 2>&1
}

test_rsync_failure_falls_back_to_the_bootstrap() {
    RSYNC_RESULT=fail run_ensure_toolbox
    local rc=$?
    assert_eq 0 "$rc" "ensure_toolbox succeeds"
    assert_not_contains "$(cat "$TEST_TMPDIR/out")" "Failed to install toolbox" "no failure message"
    assert_eq "$(cat "$REPO_ROOT/system/bootstrap.sh")" "$(cat "$TEST_TMPDIR/bootstrap-input" 2>/dev/null)" "server ran system/bootstrap.sh"
}

test_working_rsync_does_not_run_the_bootstrap() {
    RSYNC_RESULT=ok run_ensure_toolbox
    assert_true test -s "$TEST_TMPDIR/rsync.log"
    assert_false test -e "$TEST_TMPDIR/bootstrap-input"
}

test_bootstrap_uses_the_configured_repository() {
    RSYNC_RESULT=fail STACKPILOT_REPO=file:///srv/repo STACKPILOT_BRANCH=dev run_ensure_toolbox
    assert_contains "$(cat "$TEST_TMPDIR/ssh.log")" "STACKPILOT_REPO=file:///srv/repo" "repository passed to the server"
    assert_contains "$(cat "$TEST_TMPDIR/ssh.log")" "STACKPILOT_BRANCH=dev" "branch passed to the server"
}

run_tests "$0"
