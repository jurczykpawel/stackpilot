#!/bin/bash
set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    mkdir -p "$TEST_TMPDIR/src/.next/standalone/admin-panel" "$TEST_TMPDIR/stack/admin-panel"
    echo '// server' > "$TEST_TMPDIR/src/.next/standalone/admin-panel/server.js"
    tar -czf "$TEST_TMPDIR/build.tar.gz" -C "$TEST_TMPDIR/src" .
    echo 'PORT=3334' > "$TEST_TMPDIR/stack/admin-panel/.env.local"
    cat > "$TEST_TMPDIR/run.sh" <<'SH'
set -e
YELLOW='\033[1;33m'; NC='\033[0m'
source "$I18N_LIB"
SH
    sed -n '/# 2. DOWNLOAD NEW VERSION/,/# 3. STOP APPLICATION/p' \
        "$REPO_ROOT/apps/sellf/update.sh" >> "$TEST_TMPDIR/run.sh"
    echo 'echo version_section_completed' >> "$TEST_TMPDIR/run.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

check_local_version_warning() {
    local lang="$1" expected="$2" output rc=0
    output=$(TOOLBOX_LANG="$lang" I18N_LIB="$REPO_ROOT/lib/i18n.sh" \
        SELLF_RELEASE_LIB="$REPO_ROOT/apps/sellf/release-verify.sh" \
        INSTALL_DIR="$TEST_TMPDIR/stack" ENV_FILE="$TEST_TMPDIR/stack/admin-panel/.env.local" \
        BUILD_FILE="$TEST_TMPDIR/build.tar.gz" RESTART_ONLY=false CURRENT_VERSION=2026.10.0 \
        YES_MODE=true bash "$TEST_TMPDIR/run.sh" 2>&1) || rc=$?
    assert_eq "0" "$rc" "archive without version information remains accepted"
    assert_contains "$output" "$expected" "missing version produces a localized warning"
    assert_contains "$output" "$(printf '\033[1;33m')⚠️" "the warning is yellow"
    assert_contains "$output" 'version_section_completed' "update continues after the warning"
}

test_local_archive_without_version_warns_in_english_and_continues() {
    check_local_version_warning en 'Archive has no version information (version.txt missing); version check skipped. Continuing.'
}

test_local_archive_without_version_warns_in_polish_and_continues() {
    check_local_version_warning pl 'Archiwum nie zawiera informacji o wersji (brak version.txt); sprawdzanie wersji pominięte. Kontynuuję.'
}

test_deploy_forwards_local_archive_version_warning() {
    local section
    section=$(sed -n '/# UPDATE MODE (--update)/,/^fi$/p' "$REPO_ROOT/local/deploy.sh")
    assert_contains "$section" 'MSG_UPDATE_LOCAL_VERSION_MISSING=' "remote update receives the selected locale's warning"
}

run_tests "$0"
