#!/bin/bash

# Unit tests for apps/listmonk/install.sh
# Docker, sudo and psql are mocked; STACK_DIR is redirected so no server is needed.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/apps/listmonk/install.sh"

source "$TESTS_DIR/test-runner.sh"

ORIGINAL_PATH="$PATH"

setup() {
    TEST_TMPDIR=$(mktemp -d)
    local bin="$TEST_TMPDIR/bin"
    mkdir -p "$bin"
    cat > "$bin/sudo" << 'EOF'
#!/bin/bash
"$@"
EOF
    cat > "$bin/docker" << EOF
#!/bin/bash
echo "docker \$*" >> "$TEST_TMPDIR/calls.log"
if [ "\$1" = "compose" ] && [ "\$2" = "ps" ]; then
    printf '{"Name":"listmonk","State":"running"}\n'
fi
EOF
    cat > "$bin/psql" << EOF
#!/bin/bash
echo "psql \$*" >> "$TEST_TMPDIR/calls.log"
EOF
    cat > "$bin/sleep" << 'EOF'
#!/bin/bash
EOF
    chmod +x "$bin"/*
    export PATH="$bin:$ORIGINAL_PATH"
}

teardown() {
    export PATH="$ORIGINAL_PATH"
    rm -rf "$TEST_TMPDIR"
}

run_install() {
    YES_MODE=true STACK_DIR="$TEST_TMPDIR/stack" DB_HOST=db.example DB_USER=lm DB_PASS=secret DB_NAME=listmonk \
        bash "$INSTALL_SH" > "$TEST_TMPDIR/out.log" 2>&1 || { cat "$TEST_TMPDIR/out.log" >&2; return 1; }
}

test_enables_bounce_processing() {
    run_install
    local calls
    calls=$(cat "$TEST_TMPDIR/calls.log")
    assert_contains "$calls" "bounce.enabled" "settings SQL enables bounce processing"
    assert_contains "$calls" "bounce.webhooks_enabled" "settings SQL enables bounce webhooks"
    assert_contains "$calls" "bounce.ses_enabled" "settings SQL enables the SES webhook"
    assert_contains "$calls" "maintenance.db" "settings SQL keeps the daily vacuum"
}

test_restarts_after_settings_so_they_take_effect() {
    run_install
    local psql_line restart_line
    psql_line=$(grep -n '^psql' "$TEST_TMPDIR/calls.log" | head -1 | cut -d: -f1)
    restart_line=$(grep -n '^docker compose restart listmonk' "$TEST_TMPDIR/calls.log" | head -1 | cut -d: -f1)
    local ordered=no
    [ -n "$restart_line" ] && [ -n "$psql_line" ] && [ "$restart_line" -gt "$psql_line" ] && ordered=yes
    assert_eq "yes" "$ordered" "listmonk restarts after settings are written (settings load only at startup)"
}

run_tests "$0"
