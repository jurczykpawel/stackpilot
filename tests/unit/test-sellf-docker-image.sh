#!/bin/bash

# Unit tests for the Docker image manifest support in apps/sellf/release-verify.sh
# Covers the signed sellf-image.manifest (separate from the tarball manifest),
# the digest-pinned pull + version-label check + migrations extraction +
# docker-compose.yml generation done by sellf_docker_deploy, and the version
# order rule reused from the tarball path. Every test signs its own manifest
# with a throwaway Ed25519 key.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
LIB="$REPO_ROOT/apps/sellf/release-verify.sh"
DOCKER_MOCK="$REPO_ROOT/tests/mocks/docker"

source "$TESTS_DIR/test-runner.sh"

# =============================================================================
# Helpers
# =============================================================================

ORIG_PATH="$PATH"
EXPECTED_REPO="ghcr.io/jurczykpawel/sellf"

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
    unset SELLF_IMAGE_REF SELLF_RELEASE_VERSION RELEASE_FIXTURES MOCK_DOCKER_LOG \
        MOCK_DOCKER_EXIT MOCK_DOCKER_PULL_EXIT MOCK_DOCKER_INSPECT_EXIT \
        MOCK_DOCKER_CREATE_EXIT MOCK_DOCKER_CP_EXIT MOCK_DOCKER_RM_EXIT \
        MOCK_DOCKER_IMAGE_VERSION_LABEL MOCK_DOCKER_SUPABASE_SRC MOCK_DOCKER_CID
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# sign_image_manifest DIR VERSION IMAGE_REF — writes a correctly signed
# sellf-image.manifest + .sig pair in DIR.
sign_image_manifest() {
    local dir="$1" version="$2" image_ref="$3"
    mkdir -p "$dir"
    printf 'version=%s\nimage=%s\n' "$version" "$image_ref" > "$dir/sellf-image.manifest"
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/release.key" -rawin \
        -in "$dir/sellf-image.manifest" -out "$dir/sellf-image.manifest.sig"
}

# make_image_manifest DIR [VERSION] [DIGEST] — a complete, correctly signed
# image manifest pointing at EXPECTED_REPO.
make_image_manifest() {
    local dir="$1" version="${2:-2026.9.3}"
    local digest="${3:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    sign_image_manifest "$dir" "$version" "$EXPECTED_REPO@sha256:$digest"
}

# assert_image_refused DIR MESSAGE — sellf_verify_image_manifest fails.
assert_image_refused() {
    local out rc
    out=$(sellf_verify_image_manifest "$1" "$EXPECTED_REPO" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "$2"
}

# Mock curl that serves fixed files by basename, same pattern as
# test-sellf-release-verify.sh's install_mock_curl.
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

# install_mock_docker — puts the shared docker mock first on PATH and points
# its log at a per-test file.
install_mock_docker() {
    mkdir -p "$TEST_TMPDIR/dockerbin"
    ln -sf "$DOCKER_MOCK" "$TEST_TMPDIR/dockerbin/docker"
    export PATH="$TEST_TMPDIR/dockerbin:$PATH"
    export MOCK_DOCKER_LOG="$TEST_TMPDIR/docker.log"
    : > "$MOCK_DOCKER_LOG"
}

docker_log() {
    [ -f "$MOCK_DOCKER_LOG" ] && cat "$MOCK_DOCKER_LOG" || true
}

# =============================================================================
# sellf_verify_image_manifest — signature + strict format
# =============================================================================

test_valid_image_manifest_passes() {
    local digest
    digest=$(printf '1%.0s' $(seq 1 64))
    make_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$digest"
    local rc=0
    sellf_verify_image_manifest "$TEST_TMPDIR/rel" "$EXPECTED_REPO" > /dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "correctly signed image manifest is accepted"
    assert_eq "2026.9.3" "$SELLF_RELEASE_VERSION" "version is read from the image manifest"
    assert_eq "$EXPECTED_REPO@sha256:$digest" "$SELLF_IMAGE_REF" "image ref is set from the manifest"
}

test_tampered_image_manifest_fails() {
    make_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$(printf '2%.0s' $(seq 1 64))"
    sed -i.bak 's/^version=2026.9.3$/version=2026.9.4/' "$TEST_TMPDIR/rel/sellf-image.manifest"
    rm -f "$TEST_TMPDIR/rel/sellf-image.manifest.bak"
    assert_image_refused "$TEST_TMPDIR/rel" "manifest edited after signing is refused"
}

test_image_signature_from_other_key_fails() {
    make_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$(printf '3%.0s' $(seq 1 64))"
    openssl genpkey -algorithm ed25519 -out "$TEST_TMPDIR/other.key" 2>/dev/null
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/other.key" -rawin \
        -in "$TEST_TMPDIR/rel/sellf-image.manifest" -out "$TEST_TMPDIR/rel/sellf-image.manifest.sig"
    local out
    out=$(sellf_verify_image_manifest "$TEST_TMPDIR/rel" "$EXPECTED_REPO" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "signature from another key is refused"
    assert_contains "$out" "signature" "message names the signature check"
}

test_image_manifest_missing_sig_fails() {
    make_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$(printf '4%.0s' $(seq 1 64))"
    rm -f "$TEST_TMPDIR/rel/sellf-image.manifest.sig"
    local out rc
    out=$(sellf_verify_image_manifest "$TEST_TMPDIR/rel" "$EXPECTED_REPO" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "image manifest without a signature is refused"
    assert_contains "$out" "sellf-image.manifest.sig" "message names the missing file"
}

test_image_manifest_wrong_repo_fails() {
    sign_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "ghcr.io/someone-else/sellf@sha256:$(printf '5%.0s' $(seq 1 64))"
    local out rc
    out=$(sellf_verify_image_manifest "$TEST_TMPDIR/rel" "$EXPECTED_REPO" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "a signed manifest for a different repo is refused"
    assert_contains "$out" "$EXPECTED_REPO" "message names the expected repo"
}

test_image_manifest_wrong_registry_fails() {
    sign_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "docker.io/jurczykpawel/sellf@sha256:$(printf '6%.0s' $(seq 1 64))"
    assert_image_refused "$TEST_TMPDIR/rel" "a signed manifest for a different registry is refused"
}

test_image_manifest_tag_instead_of_digest_fails() {
    sign_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$EXPECTED_REPO:2026.9.3"
    assert_image_refused "$TEST_TMPDIR/rel" "a tag reference instead of a digest is refused"
}

test_image_manifest_uppercase_digest_fails() {
    sign_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$EXPECTED_REPO@sha256:$(printf 'A%.0s' $(seq 1 64))"
    assert_image_refused "$TEST_TMPDIR/rel" "an uppercase digest is refused"
}

test_image_manifest_short_digest_fails() {
    sign_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$EXPECTED_REPO@sha256:$(printf '7%.0s' $(seq 1 10))"
    assert_image_refused "$TEST_TMPDIR/rel" "a short digest is refused"
}

test_image_manifest_non_calver_version_fails() {
    sign_image_manifest "$TEST_TMPDIR/rel" "latest" "$EXPECTED_REPO@sha256:$(printf '8%.0s' $(seq 1 64))"
    assert_image_refused "$TEST_TMPDIR/rel" "a non-CalVer version is refused"
}

test_image_manifest_extra_line_fails() {
    make_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$(printf '9%.0s' $(seq 1 64))"
    printf 'channel=beta\n' >> "$TEST_TMPDIR/rel/sellf-image.manifest"
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/release.key" -rawin \
        -in "$TEST_TMPDIR/rel/sellf-image.manifest" -out "$TEST_TMPDIR/rel/sellf-image.manifest.sig"
    local out rc
    out=$(sellf_verify_image_manifest "$TEST_TMPDIR/rel" "$EXPECTED_REPO" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "an image manifest with a third line is refused"
    assert_contains "$out" "manifest" "message names the manifest format"
}

test_image_manifest_without_final_newline_fails() {
    make_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$(printf 'a%.0s' $(seq 1 64))"
    printf '%s' "$(cat "$TEST_TMPDIR/rel/sellf-image.manifest")" > "$TEST_TMPDIR/rel/m"
    mv "$TEST_TMPDIR/rel/m" "$TEST_TMPDIR/rel/sellf-image.manifest"
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/release.key" -rawin \
        -in "$TEST_TMPDIR/rel/sellf-image.manifest" -out "$TEST_TMPDIR/rel/sellf-image.manifest.sig"
    assert_image_refused "$TEST_TMPDIR/rel" "an image manifest without a final newline is refused"
}

test_image_manifest_with_crlf_fails() {
    make_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$(printf 'b%.0s' $(seq 1 64))"
    sed -i.bak 's/$/\r/' "$TEST_TMPDIR/rel/sellf-image.manifest"
    rm -f "$TEST_TMPDIR/rel/sellf-image.manifest.bak"
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/release.key" -rawin \
        -in "$TEST_TMPDIR/rel/sellf-image.manifest" -out "$TEST_TMPDIR/rel/sellf-image.manifest.sig"
    assert_image_refused "$TEST_TMPDIR/rel" "an image manifest with CRLF line endings is refused"
}

# =============================================================================
# Cross-format replay: the two manifests must never verify under each other's parser
# =============================================================================

test_tarball_manifest_rejected_by_image_verifier() {
    mkdir -p "$TEST_TMPDIR/rel"
    printf 'version=2026.9.3\nsha256=%s\n' "$(printf 'c%.0s' $(seq 1 64))" > "$TEST_TMPDIR/rel/sellf-build.manifest"
    cp "$TEST_TMPDIR/rel/sellf-build.manifest" "$TEST_TMPDIR/rel/sellf-image.manifest"
    openssl pkeyutl -sign -inkey "$TEST_TMPDIR/release.key" -rawin \
        -in "$TEST_TMPDIR/rel/sellf-image.manifest" -out "$TEST_TMPDIR/rel/sellf-image.manifest.sig"
    assert_image_refused "$TEST_TMPDIR/rel" "a tarball-shaped manifest (line 2 sha256=) is rejected by the image verifier"
}

test_image_manifest_rejected_by_tarball_parser() {
    make_image_manifest "$TEST_TMPDIR/rel" "2026.9.3" "$(printf 'd%.0s' $(seq 1 64))"
    local out rc
    out=$(sellf_parse_manifest "$TEST_TMPDIR/rel/sellf-image.manifest" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "an image-shaped manifest (line 2 image=) is rejected by the tarball parser"
}

# =============================================================================
# Download
# =============================================================================

test_image_manifest_download_fetches_all_assets() {
    make_image_manifest "$TEST_TMPDIR/fixtures" "2026.9.3" "$(printf 'e%.0s' $(seq 1 64))"
    export RELEASE_FIXTURES="$TEST_TMPDIR/fixtures"
    install_mock_curl
    mkdir -p "$TEST_TMPDIR/dl"
    local rc=0
    sellf_download_image_manifest "$TEST_TMPDIR/dl" "https://github.com/o/r/releases/download/v2026.9.3" > /dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "download succeeds"
    assert_exit_code 0 sellf_verify_image_manifest "$TEST_TMPDIR/dl" "$EXPECTED_REPO"
}

test_image_manifest_download_without_signature_asset_fails() {
    make_image_manifest "$TEST_TMPDIR/fixtures" "2026.9.3" "$(printf 'f%.0s' $(seq 1 64))"
    rm -f "$TEST_TMPDIR/fixtures/sellf-image.manifest.sig"
    export RELEASE_FIXTURES="$TEST_TMPDIR/fixtures"
    install_mock_curl
    mkdir -p "$TEST_TMPDIR/dl"
    local out rc
    out=$(sellf_download_image_manifest "$TEST_TMPDIR/dl" "https://github.com/o/r/releases/download/v2026.9.3" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "missing signature asset stops the download"
    assert_contains "$out" "sellf-image.manifest.sig" "message names the missing asset"
}

# =============================================================================
# sellf_docker_deploy — the orchestrator used by install.sh and update.sh
# =============================================================================

# stub_release_base_url URL — overrides sellf_release_base_url for the rest of
# the test so sellf_docker_deploy does not need a real GitHub redirect to mock.
stub_release_base_url() {
    local url="$1"
    # shellcheck disable=SC2317
    sellf_release_base_url() { echo "$url"; }
}

setup_docker_deploy_fixture() {
    local version="$1" digest="$2"
    make_image_manifest "$TEST_TMPDIR/fixtures" "$version" "$digest"
    export RELEASE_FIXTURES="$TEST_TMPDIR/fixtures"
    install_mock_curl
    install_mock_docker
    stub_release_base_url "https://example.test/download"
}

test_docker_deploy_pulls_by_digest_never_latest() {
    local digest
    digest=$(printf '0%.0s' $(seq 1 64))
    setup_docker_deploy_fixture "2026.9.3" "$digest"
    export MOCK_DOCKER_IMAGE_VERSION_LABEL="2026.9.3"
    mkdir -p "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest"
    local rc=0
    sellf_docker_deploy "jurczykpawel/sellf" "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest" "sellf-default" "" > /dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "docker deploy succeeds for a fresh install (no current version)"
    assert_contains "$(docker_log)" "pull $EXPECTED_REPO@sha256:$digest" "docker pull uses the verified digest"
    assert_not_contains "$(docker_log)" ":latest" "docker pull never uses the :latest tag"
    assert_contains "$(cat "$TEST_TMPDIR/stack/docker-compose.yml")" "$EXPECTED_REPO@sha256:$digest" "compose file pins the digest"
}

test_docker_deploy_writes_watchtower_opt_out_label() {
    local digest
    digest=$(printf '1%.0s' $(seq 1 64))
    setup_docker_deploy_fixture "2026.9.3" "$digest"
    export MOCK_DOCKER_IMAGE_VERSION_LABEL="2026.9.3"
    mkdir -p "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest"
    sellf_docker_deploy "jurczykpawel/sellf" "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest" "sellf-default" "" > /dev/null 2>&1
    assert_contains "$(cat "$TEST_TMPDIR/stack/docker-compose.yml")" 'com.centurylinklabs.watchtower.enable: "false"' \
        "compose file opts the container out of Watchtower"
}

test_docker_deploy_label_mismatch_aborts() {
    local digest
    digest=$(printf '2%.0s' $(seq 1 64))
    setup_docker_deploy_fixture "2026.9.3" "$digest"
    export MOCK_DOCKER_IMAGE_VERSION_LABEL="2026.9.2"  # pulled image disagrees with the signed manifest
    mkdir -p "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest"
    local out rc
    out=$(sellf_docker_deploy "jurczykpawel/sellf" "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest" "sellf-default" "" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "a label mismatch after pull aborts the deploy"
    assert_contains "$out" "2026.9.2" "message names the label actually found"
    assert_false test -f "$TEST_TMPDIR/stack/docker-compose.yml"
    assert_not_contains "$(docker_log)" "create" "migrations are never extracted after a label mismatch"
}

test_docker_deploy_downgrade_refused() {
    local digest
    digest=$(printf '3%.0s' $(seq 1 64))
    setup_docker_deploy_fixture "2026.9.2" "$digest"
    mkdir -p "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest"
    local out rc
    out=$(sellf_docker_deploy "jurczykpawel/sellf" "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest" "sellf-default" "2026.9.3" 2>&1) && rc=0 || rc=$?
    assert_not_eq "0" "$rc" "an older release than the installed version is refused"
    assert_contains "$out" "older" "message says the release is older"
    assert_eq "" "$(docker_log)" "nothing is pulled before the downgrade check"
}

test_docker_deploy_equal_version_allowed() {
    local digest
    digest=$(printf '4%.0s' $(seq 1 64))
    setup_docker_deploy_fixture "2026.9.3" "$digest"
    export MOCK_DOCKER_IMAGE_VERSION_LABEL="2026.9.3"
    mkdir -p "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest"
    assert_exit_code 0 sellf_docker_deploy "jurczykpawel/sellf" "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest" "sellf-default" "2026.9.3"
    assert_contains "$(docker_log)" "pull $EXPECTED_REPO@sha256:$digest" "re-deploying the installed version still pulls and verifies"
}

test_docker_deploy_missing_image_manifest_fails_before_pull() {
    export RELEASE_FIXTURES="$TEST_TMPDIR/no-fixtures-here"
    mkdir -p "$RELEASE_FIXTURES"
    install_mock_curl
    install_mock_docker
    stub_release_base_url "https://example.test/download"
    mkdir -p "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest"
    local rc=0
    sellf_docker_deploy "jurczykpawel/sellf" "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest" "sellf-default" "" > /dev/null 2>&1 || rc=$?
    assert_not_eq "0" "$rc" "a release without a signed image manifest is refused"
    assert_eq "" "$(docker_log)" "nothing is pulled when there is no image manifest"
    assert_false test -f "$TEST_TMPDIR/stack/docker-compose.yml"
}

test_docker_deploy_extracts_migrations_from_image() {
    local digest
    digest=$(printf '5%.0s' $(seq 1 64))
    setup_docker_deploy_fixture "2026.9.3" "$digest"
    export MOCK_DOCKER_IMAGE_VERSION_LABEL="2026.9.3"
    mkdir -p "$TEST_TMPDIR/image-supabase/migrations"
    echo "select 1;" > "$TEST_TMPDIR/image-supabase/migrations/0001_init.sql"
    export MOCK_DOCKER_SUPABASE_SRC="$TEST_TMPDIR/image-supabase"
    mkdir -p "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest"
    assert_exit_code 0 sellf_docker_deploy "jurczykpawel/sellf" "$TEST_TMPDIR/stack" "$TEST_TMPDIR/migrations-dest" "sellf-default" ""
    assert_true test -f "$TEST_TMPDIR/migrations-dest/supabase/migrations/0001_init.sql"
}

# =============================================================================
# Scripts use the shared Docker deploy path, never a bare :latest pull
# =============================================================================

test_install_never_pulls_ghcr_latest_tag() {
    local hits
    hits=$(grep -nE 'ghcr\.io[^"'"'"']*:latest' "$REPO_ROOT/apps/sellf/install.sh" || true)
    assert_eq "" "$hits" "install.sh never references ghcr.io/...:latest"
}

test_update_never_pulls_ghcr_latest_tag() {
    local hits
    hits=$(grep -nE 'ghcr\.io[^"'"'"']*:latest' "$REPO_ROOT/apps/sellf/update.sh" || true)
    assert_eq "" "$hits" "update.sh never references ghcr.io/...:latest"
}

test_install_uses_shared_docker_deploy_function() {
    assert_contains "$(cat "$REPO_ROOT/apps/sellf/install.sh")" "sellf_docker_deploy" \
        "install.sh's Docker branch calls the shared verify+pull+compose+migrations function"
}

test_update_uses_shared_docker_deploy_function() {
    assert_contains "$(cat "$REPO_ROOT/apps/sellf/update.sh")" "sellf_docker_deploy" \
        "update.sh's Docker branch calls the shared verify+pull+compose+migrations function"
}

test_update_docker_branch_never_calls_pm2() {
    local section
    section=$(sed -n '/# ----- SELLF DOCKER UPDATE START -----/,/# ----- SELLF DOCKER UPDATE END -----/p' "$REPO_ROOT/apps/sellf/update.sh")
    assert_not_eq "" "$section" "update.sh has a marked Docker update section"
    assert_not_contains "$section" "pm2" "the Docker update section never shells out to pm2"
}

test_deploy_passes_runtime_to_update() {
    local section
    section=$(sed -n '/# UPDATE MODE (--update)/,/^fi$/p' "$REPO_ROOT/local/deploy.sh")
    assert_contains "$section" "RUNTIME=" "deploy.sh forwards RUNTIME to update.sh in --update mode"
}

# =============================================================================
# Run
# =============================================================================

run_tests "$0"
