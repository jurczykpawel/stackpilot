#!/bin/bash
set -e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"
setup() {
    TEST_TMPDIR=$(mktemp -d)
    mkdir -p "$TEST_TMPDIR/tests/static" "$TEST_TMPDIR/apps/example"
    cp "$REPO_ROOT/tests/static/test-compose-syntax.sh" "$TEST_TMPDIR/tests/static/"
}
teardown() { rm -rf "$TEST_TMPDIR"; }
validate_fixture() { bash "$TEST_TMPDIR/tests/static/test-compose-syntax.sh" > "$TEST_TMPDIR/output" 2>&1; }
write_fixture() {
    cat > "$TEST_TMPDIR/apps/example/install.sh" <<'FIXTURE'
#!/bin/bash
exit 99
cat <<'CONFIG' | tee application.yaml
not: [valid
CONFIG
cat <<COMPOSE | tee docker-compose.yaml
services:
  app:
    image: example:${IMAGE_TAG}
    environment:
      PASSWORD: \${DB_PASSWORD:?required}
    ports:
      - "${BIND_ADDR}${PORT}:8080"
COMPOSE
FIXTURE
}
test_compose_target_and_expansion_without_running_installer() {
    write_fixture
    assert_true validate_fixture
    assert_contains "$(cat "$TEST_TMPDIR/output")" 'Passed: 1'
}
test_quoted_compose_uses_compose_interpolation() {
    write_fixture
    sed "s/<<COMPOSE/<<'COMPOSE'/" "$TEST_TMPDIR/apps/example/install.sh" > "$TEST_TMPDIR/quoted"
    # Quoted shell heredocs need no backslash to defer a dollar to Compose.
    sed 's/\\\$/\$/g' "$TEST_TMPDIR/quoted" > "$TEST_TMPDIR/apps/example/install.sh"
    assert_true validate_fixture
}
test_invalid_compose_remains_a_failure() {
    write_fixture
    sed 's/image: example:/image: [example:/' "$TEST_TMPDIR/apps/example/install.sh" > "$TEST_TMPDIR/invalid"
    cp "$TEST_TMPDIR/invalid" "$TEST_TMPDIR/apps/example/install.sh"
    assert_false validate_fixture
    assert_contains "$(cat "$TEST_TMPDIR/output")" 'Failed: 1'
}
run_tests "$0"
