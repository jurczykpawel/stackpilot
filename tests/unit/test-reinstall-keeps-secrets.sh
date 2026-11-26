#!/bin/bash

# Running an installer again (README: "How do I update an app?") must keep the
# secrets of the existing installation: stored data stays readable and bundled
# databases accept the password. Every installer runs twice against the same
# STACK_DIR with Docker, sudo and the network mocked; the configuration files
# it writes must be identical after the second run.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

ORIGINAL_PATH="$PATH"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    local bin="$TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/bin/bash\n"$@"\n' > "$bin/sudo"
    cat > "$bin/docker" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "compose ps") printf '{"Name":"app","State":"running","Health":"healthy"}\n' ;;
    "compose version") echo "Docker Compose version v2.30.0" ;;
    inspect*) echo healthy ;;
esac
exit 0
EOF
    printf '#!/bin/bash\nexit 0\n' > "$bin/sleep"
    printf '#!/bin/bash\nexit 0\n' > "$bin/sp-expose"
    printf '#!/bin/bash\nexit 0\n' > "$bin/systemctl"
    # Health checks succeed; downloads (-o FILE) get placeholder content
    cat > "$bin/curl" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && { out="$2"; shift; }; shift; done
[ -z "$out" ] || echo "# placeholder" > "$out"
echo "pong"
EOF
    # A clone gets the files the installers read from it (Supabase: docker/.env.example)
    cat > "$bin/git" <<'EOF'
#!/bin/bash
[ "$1" = clone ] || exit 0
dir="${@: -1}"
mkdir -p "$dir/docker"
printf 'services:\n  kong:\n    ports:\n      - ${KONG_HTTP_PORT}:8000/tcp\n' > "$dir/docker/docker-compose.yml"
printf '%s=\n' POSTGRES_PASSWORD JWT_SECRET ANON_KEY SERVICE_ROLE_KEY SECRET_KEY_BASE VAULT_ENC_KEY \
    PG_META_CRYPTO_KEY DASHBOARD_PASSWORD POOLER_TENANT_ID > "$dir/docker/.env.example"
EOF
    chmod +x "$bin"/*
    export PATH="$bin:$REPO_ROOT/tests/mocks:$ORIGINAL_PATH" MOCK_FREE_TOTAL=8192 MOCK_FREE_AVAILABLE=6144
}

teardown() {
    export PATH="$ORIGINAL_PATH"
    rm -rf "$TEST_TMPDIR"
}

# install_twice APP [VAR=value...] — prints "same" when the second run kept every config file
install_twice() {
    local app="$1" stack="$TEST_TMPDIR/stacks/$1" script="$TEST_TMPDIR/$1-install.sh" run
    shift
    # The server keeps the toolbox in /opt/stackpilot; here the checkout stands in for it
    sed "s#/opt/stackpilot/lib/#$REPO_ROOT/lib/#g" "$REPO_ROOT/apps/$app/install.sh" > "$script"
    for run in 1 2; do
        (cd "$TEST_TMPDIR" && env "$@" STACK_DIR="$stack" STACKS_DIR="$TEST_TMPDIR/stacks" STACKPILOT_LIB="$REPO_ROOT/lib" STACKPILOT_DIR="$REPO_ROOT" YES_MODE=true \
            DOMAIN_TYPE=local LC_ALL=C bash "$script") > "$TEST_TMPDIR/$app-$run.log" 2>&1 \
            || { echo "run $run failed:"; tail -5 "$TEST_TMPDIR/$app-$run.log"; return 0; }
        find "$stack" -maxdepth 1 -type f ! -name '*.log' -exec sh -c 'for f; do echo "== $f"; cat "$f"; done' sh {} + \
            > "$TEST_TMPDIR/$app-config-$run"
        grep -q '^== ' "$TEST_TMPDIR/$app-config-$run" || { echo "run $run wrote no files to $stack"; return 0; }
    done
    if cmp -s "$TEST_TMPDIR/$app-config-1" "$TEST_TMPDIR/$app-config-2"; then
        echo same
    else
        diff "$TEST_TMPDIR/$app-config-1" "$TEST_TMPDIR/$app-config-2" | head -6
    fi
}

EXTERNAL_DB=(DB_HOST=db.example DB_PORT=5432 DB_USER=app DB_PASS=secret DB_NAME=app)

test_typebot() { assert_eq same "$(install_twice typebot "${EXTERNAL_DB[@]}")"; }
test_umami() { assert_eq same "$(install_twice umami "${EXTERNAL_DB[@]}")"; }
test_keila() { assert_eq same "$(install_twice keila "${EXTERNAL_DB[@]}")"; }
test_cap() { assert_eq same "$(install_twice cap DOMAIN=cap.example.com MYSQL_ROOT_PASS=rootpass1234 USE_LOCAL_MINIO=true)"; }
test_affine() { assert_eq same "$(install_twice affine)"; }
test_convertx() { assert_eq same "$(install_twice convertx)"; }
test_crawl4ai() { assert_eq same "$(install_twice crawl4ai)"; }
test_immich() { assert_eq same "$(install_twice immich)"; }
test_minio() { assert_eq same "$(install_twice minio)"; }
test_gotenberg() { assert_eq same "$(install_twice gotenberg)"; }
test_redis() { assert_eq same "$(install_twice redis)"; }
test_social_media_generator() { assert_eq same "$(install_twice social-media-generator)"; }
test_postiz() { assert_eq same "$(install_twice postiz POSTIZ_REDIS=bundled)"; }
test_supabase() {
    # The installer edits .env with GNU sed -i, as on the server
    sed --version >/dev/null 2>&1 || { skip_test "needs GNU sed"; return 0; }
    assert_eq same "$(install_twice supabase)"
}

run_tests "$0"
