#!/bin/bash

# lib/stack-config.sh: stack_value reads what an earlier installation wrote.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"
source "$REPO_ROOT/lib/stack-config.sh"

sudo() { "$@"; }

setup() {
    TEST_TMPDIR=$(mktemp -d)
    cat > "$TEST_TMPDIR/docker-compose.yaml" <<'EOF'
services:
  app:
    environment:
      - ENCRYPTION_SECRET=abc/def+ghi=
      - DATABASE_URL=postgresql://u:p@db:5432/x?schema=y
  db:
    environment:
      POSTGRES_PASSWORD: s3cret
      QUOTED: "with space"
EOF
    printf 'JWT_SECRET=one\nJWT_SECRET_OLD=two\nEMPTY=\n' > "$TEST_TMPDIR/.env"
}

test_compose_list_entry() {
    assert_eq 'abc/def+ghi=' "$(stack_value "$TEST_TMPDIR/docker-compose.yaml" ENCRYPTION_SECRET)"
    assert_eq 'postgresql://u:p@db:5432/x?schema=y' "$(stack_value "$TEST_TMPDIR/docker-compose.yaml" DATABASE_URL)"
}

test_compose_map_entry_and_quotes() {
    assert_eq 's3cret' "$(stack_value "$TEST_TMPDIR/docker-compose.yaml" POSTGRES_PASSWORD)"
    assert_eq 'with space' "$(stack_value "$TEST_TMPDIR/docker-compose.yaml" QUOTED)"
}

test_env_file_matches_the_whole_key() {
    assert_eq 'one' "$(stack_value "$TEST_TMPDIR/.env" JWT_SECRET)"
    assert_eq 'two' "$(stack_value "$TEST_TMPDIR/.env" JWT_SECRET_OLD)"
}

test_missing_values_fail() {
    assert_false stack_value "$TEST_TMPDIR/.env" EMPTY
    assert_false stack_value "$TEST_TMPDIR/.env" ABSENT
    assert_false stack_value "$TEST_TMPDIR/none" JWT_SECRET
}

test_fallback_runs_only_without_a_value() {
    assert_eq 'one' "$(stack_value "$TEST_TMPDIR/.env" JWT_SECRET || echo generated)"
    assert_eq 'generated' "$(stack_value "$TEST_TMPDIR/.env" ABSENT || echo generated)"
}

run_tests "$0"
