#!/bin/bash

# deploy.sh retries the installer once after a containerd storage error. The first
# run removes every file it uploaded, so the retry must upload all of them again:
# each /tmp path the remote command names has to exist when the command runs.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

BLOCK=$(sed -n '/^# Upload script to server and execute/,/^# SELLF POST-INSTALLATION CONFIGURATION/p' "$REPO_ROOT/local/deploy.sh")

# run_deploy APP [BUILD_FILE] — the first installer run fails with a containerd error, the retry succeeds
run_deploy() {
    (
        REMOTE="$TEST_TMPDIR/remote"
        mkdir -p "$REMOTE/tmp"
        APP_NAME="$1" BUILD_FILE="${2:-}" SSH_ALIAS=vps YES_MODE=true EXTRA_ENV="" PORT_ENV="" DB_ENV_VARS="" DOMAIN_ENV=""
        SCRIPT_PATH="$REPO_ROOT/apps/$1/install.sh"
        msg() { :; }
        is_on_server() { return 1; }
        server_exec() { bash -c "${1//\/tmp\//$REMOTE/tmp/}"; }
        server_copy() { cp "$1" "$REMOTE$2"; }
        scp() {
            [ "$1" != -q ] || shift
            cp "$1" "$REMOTE${2#*:}"
        }
        ssh() {
            if [ "$1" != -t ]; then
                case "$2" in *journalctl*) echo 1 ;; esac
                return 0
            fi
            local path attempt
            for path in $(grep -oE "/tmp/[A-Za-z0-9._-]+" <<< "$3" | sort -u); do
                [ -e "$REMOTE$path" ] || echo "missing $path" >> "$TEST_TMPDIR/calls"
            done
            rm -rf "${REMOTE:?}/tmp/"*
            echo run >> "$TEST_TMPDIR/runs"
            attempt=$(wc -l < "$TEST_TMPDIR/runs")
            [ "$attempt" -gt 1 ]
        }
        eval "$BLOCK"
        echo "deployed" >> "$TEST_TMPDIR/calls"
    ) > "$TEST_TMPDIR/out" 2>&1 || true
}

test_sellf_retry_uploads_every_file_again() {
    echo build > "$TEST_TMPDIR/sellf-build.tar.gz"
    run_deploy sellf "$TEST_TMPDIR/sellf-build.tar.gz"
    assert_eq "2" "$(wc -l < "$TEST_TMPDIR/runs" | tr -d ' ')" "installer ran twice"
    assert_eq "deployed" "$(cat "$TEST_TMPDIR/calls")" "both runs found every uploaded file"
}

test_wordpress_retry_uploads_every_file_again() {
    run_deploy wordpress
    assert_eq "2" "$(wc -l < "$TEST_TMPDIR/runs" | tr -d ' ')" "installer ran twice"
    assert_eq "deployed" "$(cat "$TEST_TMPDIR/calls")" "both runs found every uploaded file"
}

run_tests "$0"
