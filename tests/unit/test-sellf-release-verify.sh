#!/bin/bash

# Unit tests for apps/sellf/release-verify.sh
# Covers the signed release manifest check, the checksum binding, the version
# order used by updates, archive entry validation and the release download.
# Every test signs its own release with a throwaway Ed25519 key.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
LIB="$REPO_ROOT/apps/sellf/release-verify.sh"

source "$TESTS_DIR/test-runner.sh"

# =============================================================================
# Helpers
# =============================================================================

ORIG_PATH="$PATH"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    openssl genpkey -algorithm ed25519 -out "$TEST_TMPDIR/release.key" 2>/dev/null
    openssl pkey -in "$TEST_TMPDIR/release.key" -pubout -out "$TEST_TMPDIR/release.pub.pem" 2>/dev/null
    # shellcheck source=../../apps/sellf/release-verify.sh
    source "$LIB"
    SELLF_RELEASE_PUBKEY=$(cat "$TEST_TMPDIR/release.pub.pem")
}

teardown() {
    export PATH="$ORIG_PATH"
    unset SELLF_RELEASE_VERSION RELEASE_FIXTURES
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Build a minimal Sellf-shaped archive tree in $1.
make_tree() {
    local src="$1"
    mkdir -p "$src/.next/standalone/admin-panel" "$src/public"
    echo "// server" > "$src/.next/standalone/admin-panel/server.js"
    echo "2026.9.3" > "$src/version.txt"
}

# Write manifest + checksum file + signature for the archive already in $1.
sign_release() {
    local dir="$1" version="$2" sha
    sha=$(file_sha256 "$dir/sellf-build.tar.gz")
    printf 'version=%s\nsha256=%s\n' "$version" "$sha" > "$dir/sellf-build.manifest"
    printf '%s  sellf-build.tar.gz\n' "$sha" > "$dir/sellf-build.tar.gz.sha256"
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/release.key" -rawin \
        -in "$dir/sellf-build.manifest" -out "$dir/sellf-build.manifest.sig"
}

# make_release DIR [VERSION] — a complete, correctly signed release in DIR.
make_release() {
    local dir="$1" version="${2:-2026.9.3}"
    mkdir -p "$dir" "$TEST_TMPDIR/src"
    make_tree "$TEST_TMPDIR/src"
    tar -czf "$dir/sellf-build.tar.gz" -C "$TEST_TMPDIR/src" .
    sign_release "$dir" "$version"
}

# make_crafted_archive OUT KIND — archive with one special entry (python tarfile
# writes names exactly as given, which the system tar would normalise).
make_crafted_archive() {
    python3 - "$1" "$2" <<'PY'
import io, sys, tarfile
out, kind = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:gz") as tar:
    data = b"ok\n"
    info = tarfile.TarInfo("version.txt"); info.size = len(data)
    tar.addfile(info, io.BytesIO(data))
    special = tarfile.TarInfo({"dotdot": "../outside.txt", "dotdot-tail": "public/..",
                               "absolute": "/tmp/outside.txt", "hardlink": "public/link",
                               "symlink": "public/link"}[kind])
    if kind == "hardlink":
        special.type = tarfile.LNKTYPE; special.linkname = "version.txt"
    elif kind == "symlink":
        special.type = tarfile.SYMTYPE; special.linkname = "/etc/passwd"
    elif kind == "dotdot-tail":
        special.type = tarfile.DIRTYPE
    else:
        special.size = len(data)
        tar.addfile(special, io.BytesIO(data)); special = None
    if special is not None:
        tar.addfile(special)
PY
}

# assert_refused DIR NEEDLE MESSAGE — verification fails and says why.
assert_refused() {
    local out rc
    out=$(sellf_verify_release "$1" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "$3" || return 1
    assert_contains "$out" "$2" "$3 (reason: $2)"
}

# Mock curl that serves release assets from $RELEASE_FIXTURES by file name.
install_mock_curl() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" <<'EOF'
#!/bin/bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        --proto|--proto-redir|-w) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
src="$RELEASE_FIXTURES/${url##*/}"
[ -f "$src" ] || exit 22
cp "$src" "$out"
EOF
    chmod +x "$TEST_TMPDIR/bin/curl"
    export PATH="$TEST_TMPDIR/bin:$PATH"
}

# =============================================================================
# Signed manifest
# =============================================================================

test_valid_release_passes() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"
    local rc=0
    sellf_verify_release "$TEST_TMPDIR/rel" > /dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "correctly signed release is accepted"
    assert_eq "2026.9.3" "$SELLF_RELEASE_VERSION" "release version is read from the manifest"
}

test_modified_manifest_fails() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"
    sed -i.bak 's/^version=2026.9.3$/version=2026.9.4/' "$TEST_TMPDIR/rel/sellf-build.manifest"
    rm -f "$TEST_TMPDIR/rel/sellf-build.manifest.bak"
    local out
    out=$(sellf_verify_release "$TEST_TMPDIR/rel" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "manifest edited after signing is refused"
    assert_contains "$out" "signature" "message names the signature check"
}

test_wrong_hash_fails() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"
    # A different archive than the one the signed manifest describes.
    echo "extra" > "$TEST_TMPDIR/src/extra.txt"
    tar -czf "$TEST_TMPDIR/rel/sellf-build.tar.gz" -C "$TEST_TMPDIR/src" .
    local out rc
    out=$(sellf_verify_release "$TEST_TMPDIR/rel" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "archive that differs from the manifest hash is refused"
    assert_contains "$out" "checksum" "message names the checksum check"
}

test_missing_signature_fails() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"
    rm -f "$TEST_TMPDIR/rel/sellf-build.manifest.sig"
    local out rc
    out=$(sellf_verify_release "$TEST_TMPDIR/rel" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "release without a signature is refused"
    assert_contains "$out" "sellf-build.manifest.sig" "message names the missing file"
}

test_signature_from_other_key_fails() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"
    openssl genpkey -algorithm ed25519 -out "$TEST_TMPDIR/other.key" 2>/dev/null
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/other.key" -rawin \
        -in "$TEST_TMPDIR/rel/sellf-build.manifest" -out "$TEST_TMPDIR/rel/sellf-build.manifest.sig"
    assert_refused "$TEST_TMPDIR/rel" "signature" "signature from another key is refused"
}

test_placeholder_key_refused() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"
    SELLF_RELEASE_PUBKEY=$(printf '%s\n' '-----BEGIN PUBLIC KEY-----' \
        'REPLACE_WITH_SELLF_RELEASE_PUBLIC_KEY' '-----END PUBLIC KEY-----')
    local out rc
    out=$(sellf_verify_release "$TEST_TMPDIR/rel" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "placeholder key never verifies anything"
    assert_contains "$out" "public key is not configured" "message explains the key is missing"
}

test_pinned_key_refuses_release_signed_by_other_key() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"   # signed by the throwaway key
    source "$LIB"                                # back to the pinned Sellf key
    assert_not_contains "$SELLF_RELEASE_PUBKEY" "REPLACE_WITH" "a real key is pinned"
    assert_refused "$TEST_TMPDIR/rel" "signature" "release signed by a throwaway key is refused by the pinned key"
}

test_key_block_is_single_source() {
    local blocks
    blocks=$(grep -c -- '-----BEGIN PUBLIC KEY-----' "$LIB")
    assert_eq "1" "$blocks" "exactly one pinned key in the library"
    assert_contains "$(sed -n '/sellf-release-key:start/,/sellf-release-key:end/p' "$LIB")" \
        "BEGIN PUBLIC KEY" "key sits between the paste markers"
    local elsewhere
    elsewhere=$(grep -l -- '-----BEGIN PUBLIC KEY-----' "$REPO_ROOT/apps/sellf/"*.sh "$REPO_ROOT/local/deploy.sh" | grep -v 'release-verify.sh' || true)
    assert_eq "" "$elsewhere" "no other script carries its own copy of the key"
}

test_manifest_with_extra_line_fails() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"
    printf 'channel=beta\n' >> "$TEST_TMPDIR/rel/sellf-build.manifest"
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/release.key" -rawin \
        -in "$TEST_TMPDIR/rel/sellf-build.manifest" -out "$TEST_TMPDIR/rel/sellf-build.manifest.sig"
    local out rc
    out=$(sellf_verify_release "$TEST_TMPDIR/rel" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "signed manifest with an unknown key is refused"
    assert_contains "$out" "manifest" "message names the manifest format"
}

test_manifest_without_final_newline_fails() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"
    printf '%s' "$(cat "$TEST_TMPDIR/rel/sellf-build.manifest")" > "$TEST_TMPDIR/rel/m"
    mv "$TEST_TMPDIR/rel/m" "$TEST_TMPDIR/rel/sellf-build.manifest"
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/release.key" -rawin \
        -in "$TEST_TMPDIR/rel/sellf-build.manifest" -out "$TEST_TMPDIR/rel/sellf-build.manifest.sig"
    assert_refused "$TEST_TMPDIR/rel" "manifest" "manifest without a final newline is refused"
}

test_manifest_with_crlf_fails() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"
    sed -i.bak 's/$/\r/' "$TEST_TMPDIR/rel/sellf-build.manifest"
    rm -f "$TEST_TMPDIR/rel/sellf-build.manifest.bak"
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/release.key" -rawin \
        -in "$TEST_TMPDIR/rel/sellf-build.manifest" -out "$TEST_TMPDIR/rel/sellf-build.manifest.sig"
    assert_refused "$TEST_TMPDIR/rel" "manifest" "manifest with CRLF line endings is refused"
}

test_checksum_file_disagreeing_with_manifest_fails() {
    make_release "$TEST_TMPDIR/rel" "2026.9.3"
    printf '%064d  sellf-build.tar.gz\n' 0 > "$TEST_TMPDIR/rel/sellf-build.tar.gz.sha256"
    assert_refused "$TEST_TMPDIR/rel" "checksum" "checksum file that disagrees with the manifest is refused"
}

# =============================================================================
# Version order (updates)
# =============================================================================

test_older_version_refused() {
    local out rc
    out=$(sellf_check_update_version "2026.9.3" "2026.9.2" 2>&1) && rc=0 || rc=$?
    assert_eq "1" "$rc" "older release than the installed one is refused"
    assert_contains "$out" "older" "message says the release is older"
}

test_equal_version_proceeds() {
    local out rc
    out=$(sellf_check_update_version "2026.9.3" "2026.9.3" 2>&1) && rc=0 || rc=$?
    assert_eq "0" "$rc" "re-deploying the installed version is allowed"
    assert_contains "$out" "2026.9.3" "message names the re-applied version"
}

test_newer_version_proceeds() {
    assert_exit_code 0 sellf_check_update_version "2026.9.3" "2026.9.4"
}

test_calver_month_boundary() {
    assert_exit_code 0 sellf_check_update_version "2026.9.10" "2026.10.0"
    assert_exit_code 1 sellf_check_update_version "2026.10.0" "2026.9.10"
    assert_exit_code 0 sellf_check_update_version "2026.12.4" "2027.1.0"
}

test_installed_version_with_prefix_and_whitespace() {
    # Parsed as 2026.9.3 (an unreadable version would be let through instead)
    assert_exit_code 1 sellf_check_update_version "v2026.9.3
" "2026.9.2"
}

test_unknown_installed_version_proceeds_with_warning() {
    local out rc
    out=$(sellf_check_update_version "unknown" "2026.9.3" 2>&1) && rc=0 || rc=$?
    assert_eq "0" "$rc" "install without a recorded version can still update"
    assert_contains "$out" "version" "a warning is printed"
}

test_invalid_candidate_version_refused() {
    assert_exit_code 1 sellf_check_update_version "2026.9.3" "2026.9"
}

# =============================================================================
# Archive entries
# =============================================================================

test_plain_archive_passes_entry_check() {
    make_release "$TEST_TMPDIR/rel"
    assert_exit_code 0 sellf_validate_archive "$TEST_TMPDIR/rel/sellf-build.tar.gz"
}

test_symlink_entry_refused() {
    mkdir -p "$TEST_TMPDIR/src"
    make_tree "$TEST_TMPDIR/src"
    ln -s /etc/passwd "$TEST_TMPDIR/src/public/link"
    tar -czf "$TEST_TMPDIR/a.tar.gz" -C "$TEST_TMPDIR/src" .
    local out rc
    out=$(sellf_validate_archive "$TEST_TMPDIR/a.tar.gz" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "symlink entry is refused"
    assert_contains "$out" "type" "message names the entry type"
}

test_signed_release_with_symlink_still_refused() {
    mkdir -p "$TEST_TMPDIR/src" "$TEST_TMPDIR/rel"
    make_tree "$TEST_TMPDIR/src"
    ln -s /etc/passwd "$TEST_TMPDIR/src/public/link"
    tar -czf "$TEST_TMPDIR/rel/sellf-build.tar.gz" -C "$TEST_TMPDIR/src" .
    sign_release "$TEST_TMPDIR/rel" "2026.9.3"
    assert_refused "$TEST_TMPDIR/rel" "type" "signed release with a symlink entry is refused"
}

test_crafted_entries_refused() {
    command -v python3 >/dev/null 2>&1 || { skip_test "python3 not available"; return 0; }
    local kind
    for kind in dotdot dotdot-tail absolute hardlink symlink; do
        make_crafted_archive "$TEST_TMPDIR/$kind.tar.gz" "$kind"
        assert_exit_code 1 sellf_validate_archive "$TEST_TMPDIR/$kind.tar.gz"
    done
}

test_unreadable_archive_refused() {
    echo "not an archive" > "$TEST_TMPDIR/bad.tar.gz"
    assert_exit_code 1 sellf_validate_archive "$TEST_TMPDIR/bad.tar.gz"
}

# =============================================================================
# Download
# =============================================================================

test_download_fetches_all_assets() {
    make_release "$TEST_TMPDIR/fixtures"
    export RELEASE_FIXTURES="$TEST_TMPDIR/fixtures"
    install_mock_curl
    mkdir -p "$TEST_TMPDIR/dl"
    local rc=0
    sellf_download_release "$TEST_TMPDIR/dl" "https://github.com/o/r/releases/download/v2026.9.3" > /dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "download succeeds"
    assert_exit_code 0 sellf_verify_release "$TEST_TMPDIR/dl"
}

test_download_without_signature_asset_fails() {
    make_release "$TEST_TMPDIR/fixtures"
    rm -f "$TEST_TMPDIR/fixtures/sellf-build.manifest.sig"
    export RELEASE_FIXTURES="$TEST_TMPDIR/fixtures"
    install_mock_curl
    mkdir -p "$TEST_TMPDIR/dl"
    local out rc
    out=$(sellf_download_release "$TEST_TMPDIR/dl" "https://github.com/o/r/releases/download/v2026.9.3" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "missing signature asset stops the download"
    assert_contains "$out" "sellf-build.manifest.sig" "message names the missing asset"
}

# =============================================================================
# Scripts use the verified path
# =============================================================================

test_scripts_never_stream_download_into_tar() {
    local hits
    hits=$(grep -nE 'curl[^|]*\|[[:space:]]*tar' "$REPO_ROOT/apps/sellf/install.sh" "$REPO_ROOT/apps/sellf/update.sh" || true)
    assert_eq "" "$hits" "no curl | tar in the Sellf install/update scripts"
}

test_scripts_check_local_build_entries() {
    assert_contains "$(cat "$REPO_ROOT/apps/sellf/install.sh")" 'sellf_validate_archive "$BUILD_FILE"' "install.sh checks a local build before extracting"
    assert_contains "$(cat "$REPO_ROOT/apps/sellf/update.sh")" 'sellf_validate_archive "$BUILD_FILE"' "update.sh checks a local build before extracting"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
