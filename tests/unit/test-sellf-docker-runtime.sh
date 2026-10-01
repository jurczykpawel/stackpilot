#!/bin/bash
set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
LIB="$REPO_ROOT/apps/sellf/release-verify.sh"
source "$TESTS_DIR/test-runner.sh"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    source "$LIB"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

write_compose() {
    sellf_write_docker_compose "$TEST_TMPDIR" "ghcr.io/example/sellf@sha256:$(printf 'a%.0s' {1..64})" "sellf-test"
}

test_compose_healthcheck_uses_runtime_port_and_health_endpoint() {
    write_compose
    local compose
    compose=$(cat "$TEST_TMPDIR/docker-compose.yml")
    assert_contains "$compose" "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/api/health')" "healthcheck uses the instance PORT and health endpoint"
    assert_contains "$compose" 'test: ["CMD", "node", "-e",' "healthcheck runs Node directly"
    assert_contains "$compose" 'interval: 30s' "healthcheck interval matches Sellf"
    assert_contains "$compose" 'timeout: 10s' "healthcheck timeout matches Sellf"
    assert_contains "$compose" 'retries: 3' "healthcheck retry count matches Sellf"
    assert_contains "$compose" 'start_period: 30s' "healthcheck allows startup time"
}

test_written_healthcheck_succeeds_on_200_and_fails_on_503() {
    write_compose
    local output rc=0
    output=$(node - "$TEST_TMPDIR/docker-compose.yml" <<'JS'
const fs = require('node:fs');
const http = require('node:http');
const {spawn} = require('node:child_process');
const line = fs.readFileSync(process.argv[2], 'utf8').split('\n').find(l => l.trim().startsWith('test: ['));
if (!line) throw new Error('generated compose has no healthcheck command');
const [mode, executable, flag, code] = JSON.parse(line.trim().slice(6));
if (mode !== 'CMD' || executable !== 'node' || flag !== '-e') throw new Error('invalid healthcheck command');
let status = 200;
const server = http.createServer((req, res) => {
  res.writeHead(req.url === '/api/health' ? status : 404);
  res.end();
});
server.listen(0, '127.0.0.1', async () => {
  try {
    for (const [response, expected] of [[200, 0], [503, 1]]) {
      status = response;
      const child = spawn(executable, [flag, code], {env: {...process.env, PORT: String(server.address().port)}, stdio: 'ignore'});
      const result = await new Promise((resolve, reject) => {
        child.on('error', reject);
        child.on('exit', resolve);
      });
      if (result !== expected) throw new Error(`HTTP ${response}: expected exit ${expected}, got ${result}`);
    }
    console.log('runtime-port probe: 200=0, 503=1');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    server.close();
  }
});
JS
    ) || rc=$?
    assert_eq "0" "$rc" "the written command probes a real server on a non-default port"
    assert_contains "$output" 'runtime-port probe: 200=0, 503=1' "HTTP response controls the healthcheck exit status"
}

test_docker_update_refreshes_env_and_recreates_same_version() {
    mkdir -p "$TEST_TMPDIR/stack/admin-panel"
    printf 'SELLF_TEST_MARKER=1\n' > "$TEST_TMPDIR/stack/admin-panel/.env.local"
    printf 'services:\n  sellf:\n    container_name: sellf-test\n' > "$TEST_TMPDIR/stack/docker-compose.yml"
    cat > "$TEST_TMPDIR/lib.sh" <<'SH'
source "$REAL_LIB"
sellf_docker_deploy() {
    SELLF_RELEASE_VERSION=2026.10.0
    SELLF_IMAGE_REF=ghcr.io/example/sellf
}
SH
    cat > "$TEST_TMPDIR/update.sh" <<'SH'
set -e
docker() { printf '%s\n' "$*" >> "$DOCKER_LOG"; }
sleep() { :; }
SH
    sed -n '/# ----- SELLF DOCKER UPDATE START -----/,/# ----- SELLF DOCKER UPDATE END -----/p' \
        "$REPO_ROOT/apps/sellf/update.sh" >> "$TEST_TMPDIR/update.sh"
    local rc=0
    REAL_LIB="$LIB" SELLF_RELEASE_LIB="$TEST_TMPDIR/lib.sh" INSTALL_DIR="$TEST_TMPDIR/stack" \
        ENV_FILE="$TEST_TMPDIR/stack/admin-panel/.env.local" CURRENT_VERSION=2026.10.0 \
        RESTART_ONLY=false YES_MODE=true DOCKER_LOG="$TEST_TMPDIR/docker.log" \
        bash "$TEST_TMPDIR/update.sh" > "$TEST_TMPDIR/output" 2>&1 || rc=$?
    assert_eq "0" "$rc" "same-version update succeeds"
    assert_true grep -q '^SELLF_TEST_MARKER=1$' "$TEST_TMPDIR/stack/.env"
    assert_contains "$(cat "$TEST_TMPDIR/docker.log")" 'compose up -d --force-recreate' \
        "same-version update recreates the container to load the refreshed env"
}

run_tests "$0"
