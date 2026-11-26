#!/bin/bash

# ensure_caddy (lib/server-exec.sh): Caddy serves sites on ports 80 and 443, so a
# port held by another program stops the deploy before anything is installed,
# naming that program. Without ss nothing can be checked, which is not "free".

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

ORIGINAL_PATH="$PATH"

stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$TEST_TMPDIR/bin/$1"
    chmod +x "$TEST_TMPDIR/bin/$1"
}

# ssh runs commands here; the Caddy installer (bash -s) is recorded and leaves caddy and sp-expose.
# ss prints the listeners in $TEST_TMPDIR/listeners, as "ss -Hltnp" does.
setup() {
    TEST_TMPDIR=$(mktemp -d)
    mkdir -p "$TEST_TMPDIR/bin"
    stub ssh 'shift
[ "$*" != "bash -s" ] || { cat > /dev/null; echo installer >> "'"$TEST_TMPDIR"'/calls"; for c in caddy sp-expose; do printf "#!/bin/bash\n" > "'"$TEST_TMPDIR"'/bin/$c"; chmod +x "'"$TEST_TMPDIR"'/bin/$c"; done; exit 0; }
exec bash -c "$*"'
    stub sudo '"$@"'
    stub ss 'cat "'"$TEST_TMPDIR"'/listeners" 2>/dev/null; exit 0'
    export PATH="$TEST_TMPDIR/bin:/usr/bin:/bin"
}

teardown() {
    export PATH="$ORIGINAL_PATH"
    rm -rf "$TEST_TMPDIR"
}

listening() { printf '%s\n' "$@" > "$TEST_TMPDIR/listeners"; }
caddy_installed() { stub caddy 'exit 0'; stub sp-expose 'exit 0'; }

run_ensure_caddy() {
    (
        export TOOLBOX_LANG=en
        source "$REPO_ROOT/lib/server-exec.sh"
        _ON_SERVER=false
        ensure_toolbox() { :; }
        ensure_caddy vps
    ) > "$TEST_TMPDIR/out" 2>&1 && STATUS=0 || STATUS=$?
    OUTPUT=$(cat "$TEST_TMPDIR/out")
}

test_port_80_held_by_another_program_stops_before_installing() {
    listening 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=812,fd=6),("nginx",pid=811,fd=6))'
    run_ensure_caddy
    assert_eq 1 "$STATUS" "ensure_caddy fails"
    assert_contains "$OUTPUT" "Port 80 is in use by nginx" "names the port and the program"
    assert_eq "" "$(cat "$TEST_TMPDIR/calls" 2>/dev/null)" "Caddy is not installed"
}

test_port_443_held_with_caddy_installed_fails() {
    caddy_installed
    listening 'LISTEN 0 4096 *:443 *:* users:(("docker-proxy",pid=90,fd=4))'
    run_ensure_caddy
    assert_eq 1 "$STATUS" "ensure_caddy fails"
    assert_contains "$OUTPUT" "Port 443 is in use by docker-proxy"
    assert_not_contains "$OUTPUT" "Caddy installed"
}

test_ports_held_by_caddy_are_fine() {
    caddy_installed
    listening 'LISTEN 0 4096 *:80 *:* users:(("caddy",pid=5,fd=7))' \
        'LISTEN 0 4096 *:443 *:* users:(("caddy",pid=5,fd=8))' \
        'LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:* users:(("node",pid=9,fd=3))'
    run_ensure_caddy
    assert_eq 0 "$STATUS" "ensure_caddy succeeds"
}

test_free_ports_install_caddy() {
    listening 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' \
        'LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:* users:(("node",pid=9,fd=3))'
    run_ensure_caddy
    assert_eq 0 "$STATUS" "ensure_caddy succeeds"
    assert_eq "installer" "$(cat "$TEST_TMPDIR/calls" 2>/dev/null)" "Caddy installed"
}

test_missing_ss_is_not_free() {
    rm "$TEST_TMPDIR/bin/ss"
    run_ensure_caddy
    assert_eq 1 "$STATUS" "ensure_caddy fails"
    assert_contains "$OUTPUT" "iproute2" "says what is missing"
    assert_eq "" "$(cat "$TEST_TMPDIR/calls" 2>/dev/null)" "Caddy is not installed"
}

run_tests "$0"
