#!/bin/bash
set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    TRACK_LINKS=false
    ORIGINAL_PATH="$PATH"
    ORIGINAL_BUN_INSTALL="${BUN_INSTALL-}"
    BUN_INSTALL="$TEST_TMPDIR/bun"
    SYSTEM_BIN="$TEST_TMPDIR/system-bin"
    mkdir -p "$BUN_INSTALL/bin" "$SYSTEM_BIN"
    for binary in bun pm2; do
        printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$binary" > "$BUN_INSTALL/bin/$binary"
        chmod +x "$BUN_INSTALL/bin/$binary"
    done
    source "$REPO_ROOT/apps/sellf/release-verify.sh"
}

teardown() {
    PATH="$ORIGINAL_PATH"
    BUN_INSTALL="$ORIGINAL_BUN_INSTALL"
    rm -rf "$TEST_TMPDIR"
}

ln() {
    if [ "${TRACK_LINKS:-false}" = true ]; then
        echo 'unexpected ln' >> "$TEST_TMPDIR/mutations"
        return 1
    fi
    command ln "$@"
}

test_missing_binaries_get_system_links() {
    sellf_ensure_system_path "$SYSTEM_BIN" || return
    for binary in bun pm2; do
        assert_eq "$BUN_INSTALL/bin/$binary" "$(readlink "$SYSTEM_BIN/$binary")"
        assert_eq "$binary" "$(PATH="$SYSTEM_BIN:/usr/bin:/bin" "$binary")"
    done
}

test_regular_files_are_untouched() {
    for binary in bun pm2; do
        printf 'existing %s\n' "$binary" > "$SYSTEM_BIN/$binary"
    done
    sellf_ensure_system_path "$SYSTEM_BIN" || return
    for binary in bun pm2; do
        assert_false test -L "$SYSTEM_BIN/$binary"
        assert_eq "existing $binary" "$(cat "$SYSTEM_BIN/$binary")"
    done
}

test_correct_links_are_no_op() {
    for binary in bun pm2; do
        ln -s "$BUN_INSTALL/bin/$binary" "$SYSTEM_BIN/$binary"
    done
    TRACK_LINKS=true
    sellf_ensure_system_path "$SYSTEM_BIN"
    local rc=$?
    TRACK_LINKS=false
    assert_eq 0 "$rc"
    assert_false test -e "$TEST_TMPDIR/mutations"
}

test_other_valid_links_are_untouched() {
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/other"
    chmod +x "$TEST_TMPDIR/other"
    for binary in bun pm2; do
        ln -s "$TEST_TMPDIR/other" "$SYSTEM_BIN/$binary"
    done
    sellf_ensure_system_path "$SYSTEM_BIN" || return
    for binary in bun pm2; do
        assert_eq "$TEST_TMPDIR/other" "$(readlink "$SYSTEM_BIN/$binary")"
    done
}

test_dangling_links_are_repaired() {
    for binary in bun pm2; do
        ln -s "$TEST_TMPDIR/missing" "$SYSTEM_BIN/$binary"
    done
    sellf_ensure_system_path "$SYSTEM_BIN" || return
    for binary in bun pm2; do
        assert_eq "$BUN_INSTALL/bin/$binary" "$(readlink "$SYSTEM_BIN/$binary")"
        assert_true test -x "$SYSTEM_BIN/$binary"
    done
}

test_repeated_calls_are_no_op() {
    sellf_ensure_system_path "$SYSTEM_BIN" || return
    TRACK_LINKS=true
    sellf_ensure_system_path "$SYSTEM_BIN"
    local rc=$?
    TRACK_LINKS=false
    assert_eq 0 "$rc"
    assert_false test -e "$TEST_TMPDIR/mutations"
}

test_install_invokes_shared_helper_after_pm2_install() {
    local block
    block=$(sed -n '/# ----- SELLF SYSTEM PATH START -----/,/# ----- SELLF SYSTEM PATH END -----/p' "$REPO_ROOT/apps/sellf/install.sh")
    assert_contains "$block" 'sellf_ensure_system_path' || return
    assert_true test "$(awk '/^    sellf_ensure_system_path$/{print NR}' "$REPO_ROOT/apps/sellf/install.sh")" -gt \
        "$(awk '/bun install -g pm2/{print NR}' "$REPO_ROOT/apps/sellf/install.sh")"
    SELLF_RELEASE_LIB="$REPO_ROOT/apps/sellf/release-verify.sh"
    eval "${block/sellf_ensure_system_path/sellf_ensure_system_path \"\$SYSTEM_BIN\"}" || return
    assert_true test -x "$SYSTEM_BIN/pm2"
    assert_true test -x "$SYSTEM_BIN/bun"
}

test_update_invokes_shared_helper_before_download() {
    local block
    block=$(sed -n '/# ----- SELLF SYSTEM PATH START -----/,/# ----- SELLF SYSTEM PATH END -----/p' "$REPO_ROOT/apps/sellf/update.sh")
    assert_contains "$block" 'sellf_ensure_system_path' || return
    local helper_line
    helper_line=$(awk '/^sellf_ensure_system_path$/{print NR}' "$REPO_ROOT/apps/sellf/update.sh")
    assert_true test "$helper_line" -gt "$(awk '/SELLF DOCKER UPDATE END/{print NR}' "$REPO_ROOT/apps/sellf/update.sh")"
    assert_true test "$helper_line" -lt "$(awk '/# 2. DOWNLOAD NEW VERSION/{print NR}' "$REPO_ROOT/apps/sellf/update.sh")"
    SELLF_RELEASE_LIB="$REPO_ROOT/apps/sellf/release-verify.sh"
    eval "${block/sellf_ensure_system_path/sellf_ensure_system_path \"\$SYSTEM_BIN\"}" || return
    assert_true test -x "$SYSTEM_BIN/pm2"
    assert_true test -x "$SYSTEM_BIN/bun"
}

check_missing_binary_error() {
    local binary="$1" lang expected output rc
    cat > "$TEST_TMPDIR/missing.sh" <<'SH'
set -e
source "$TEST_LIB"
command() {
    if [ "$1" = '-v' ] && [ "$2" = "$MISSING_BINARY" ]; then
        return 1
    fi
    builtin command "$@"
}
sellf_ensure_system_path "$TARGET_BIN"
echo setup_continued
SH
    for lang in en pl; do
        rc=0
        output=$(env TOOLBOX_LANG="$lang" \
            TEST_LIB="$REPO_ROOT/apps/sellf/release-verify.sh" BUN_INSTALL="$BUN_INSTALL" \
            TARGET_BIN="$TEST_TMPDIR/missing-$lang" MISSING_BINARY="$binary" \
            REPO_ROOT="$REPO_ROOT" bash "$TEST_TMPDIR/missing.sh" 2>&1) || rc=$?
        assert_eq 1 "$rc" "set -e exits with status 1 for missing $binary"
        if [ "$lang" = en ]; then
            expected="Cannot find executable '$binary'"
        else
            expected="Nie znaleziono pliku wykonywalnego '$binary'"
        fi
        assert_contains "$output" "$expected" "error names $binary in $lang"
        assert_contains "$output" 'bun install -g pm2' "error explains how to repair the runtime"
        assert_not_contains "$output" setup_continued "setup stops after missing $binary"
    done
}

test_missing_bun_reports_localized_error_and_exits() {
    check_missing_binary_error bun
}

test_missing_pm2_reports_localized_error_and_exits() {
    check_missing_binary_error pm2
}

test_deploy_forwards_system_path_error_for_install_and_update() {
    local update install
    update=$(sed -n '/# UPDATE MODE (--update)/,/^fi$/p' "$REPO_ROOT/local/deploy.sh")
    install=$(sed -n '/# For Sellf - add variables to EXTRA_ENV/,$p' "$REPO_ROOT/local/deploy.sh")
    assert_contains "$update" 'MSG_SELLF_SYSTEM_BINARY_MISSING=$(printf' "remote update receives the selected message"
    assert_contains "$install" 'MSG_SELLF_SYSTEM_BINARY_MISSING=$(printf' "remote install receives the selected message"
}

run_tests "$0"
