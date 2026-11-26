#!/bin/bash

# Tests for lib/port-utils.sh

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

# Load i18n and server-exec (port-utils depends on it)
export TOOLBOX_LANG=en
source "$REPO_ROOT/lib/i18n.sh"

# Mock: force "on server" mode to avoid SSH calls
_ON_SERVER=true
is_on_server() { [ "$_ON_SERVER" = true ]; }
export _ON_SERVER
export -f is_on_server

# Put mocks on PATH
export PATH="$REPO_ROOT/tests/mocks:$PATH"

source "$REPO_ROOT/lib/port-utils.sh"

# =============================================================================
# find_free_port tests
# =============================================================================

test_find_free_port_default() {
    export MOCK_SS_PORTS="80 443"
    local port
    port=$(find_free_port)
    assert_eq "8000" "$port" "default base port 8000 is free"
}

test_find_free_port_custom_base() {
    export MOCK_SS_PORTS="80 443"
    local port
    port=$(find_free_port 3000)
    assert_eq "3000" "$port" "custom base port 3000 is free"
}

test_find_free_port_skips_used() {
    export MOCK_SS_PORTS="80 443 8000 8001 8002"
    local port
    port=$(find_free_port 8000)
    assert_eq "8003" "$port" "skips used ports 8000-8002"
}

test_find_free_port_all_low_used() {
    export MOCK_SS_PORTS="5000 5001 5002 5003 5004"
    local port
    port=$(find_free_port 5000)
    assert_eq "5005" "$port" "finds 5005 when 5000-5004 are used"
}

test_find_free_port_single_used() {
    export MOCK_SS_PORTS="9000"
    local port
    port=$(find_free_port 9000)
    assert_eq "9001" "$port" "skips single used port"
}

# =============================================================================
# Run
# =============================================================================

setup() { TEST_TMPDIR=$(mktemp -d); }
teardown() { rm -rf "$TEST_TMPDIR"; }
server_exec_timeout() { bash -c "$2"; }
test_existing_port_prefers_saved_host_port() {
    printf '3561\n' > "$TEST_TMPDIR/.stackpilot-port"
    printf 'PORT=3000\n' > "$TEST_TMPDIR/.env.local"
    assert_eq 3561 "$(read_existing_app_port "$TEST_TMPDIR/.stackpilot-port" "$TEST_TMPDIR/.env.local")"
}
test_existing_port_accepts_default_as_existing() {
    printf '3560\n' > "$TEST_TMPDIR/.stackpilot-port"
    assert_eq 3560 "$(read_existing_app_port "$TEST_TMPDIR/.stackpilot-port" "$TEST_TMPDIR/missing")"
}
test_existing_port_keeps_legacy_env_support() {
    printf 'PORT=3334\n' > "$TEST_TMPDIR/.env.local"
    assert_eq 3334 "$(read_existing_app_port "$TEST_TMPDIR/missing" "$TEST_TMPDIR/.env.local")"
}
test_existing_port_rejects_invalid_values() {
    local value port rc
    for value in 0 65536 -1 abc 003560 '3560; echo extra'; do
        printf '%s\n' "$value" > "$TEST_TMPDIR/.stackpilot-port"
        rc=0
        port=$(read_existing_app_port "$TEST_TMPDIR/.stackpilot-port" "$TEST_TMPDIR/missing") || rc=$?
        assert_eq '' "$port"
        assert_not_eq 0 "$rc"
    done
}

# A server without ss: PATH holds only basic tools plus what a test adds.
minimal_path() {
    local tool
    mkdir -p "$TEST_TMPDIR/bin"
    for tool in bash sh awk grep sort id cat cp; do
        ln -sf "$(command -v "$tool")" "$TEST_TMPDIR/bin/$tool"
    done
    echo "$TEST_TMPDIR/bin"
}

test_missing_ss_is_an_error_not_a_free_port() {
    local path port rc=0
    path=$(minimal_path)
    port=$(PATH="$path" find_free_port 8000) || rc=$?
    assert_eq '' "$port" "no port reported"
    assert_not_eq 0 "$rc" "find_free_port fails"
    rc=0
    PATH="$path" listening_ports >/dev/null 2>&1 || rc=$?
    assert_not_eq 0 "$rc" "listening_ports fails"
}

test_missing_ss_is_installed_with_apt() {
    local path
    path=$(minimal_path)
    cat > "$path/apt-get" <<EOF
#!/bin/bash
echo "apt-get \$*" >> "$TEST_TMPDIR/apt.log"
[ "\$1" != install ] || cp "$REPO_ROOT/tests/mocks/ss" "$path/ss"
EOF
    printf '#!/bin/bash\n"$@"\n' > "$path/sudo"
    chmod +x "$path/apt-get" "$path/sudo"
    export MOCK_SS_PORTS="8000"
    assert_eq 8001 "$(PATH="$path" find_free_port 8000)" "port found after installing ss"
    assert_contains "$(cat "$TEST_TMPDIR/apt.log" 2>/dev/null)" "install -y -qq iproute2" "iproute2 installed"
}

test_deploy_stops_when_ports_cannot_be_listed() {
    sed -n '/^DEFAULT_PORT=/,/^# PHASE 1/p' "$REPO_ROOT/local/deploy.sh" > "$TEST_TMPDIR/phase.sh"
    printf 'PORT=31878\n' > "$TEST_TMPDIR/install.sh"
    local out rc=0
    out=$(SCRIPT_PATH="$TEST_TMPDIR/install.sh" bash -c '
        DOMAIN="" APP_NAME=app SSH_ALIAS=test
        MSG_PORT_CHECK_FAILED="cannot list ports"
        read_existing_app_port() { return 1; }
        server_exec_timeout() { echo no; }
        listening_ports() { return 127; }
        msg() { printf "%s\n" "$1"; }
        source "$1"
        echo installer-would-run' bash "$TEST_TMPDIR/phase.sh" 2>&1) || rc=$?
    assert_not_eq 0 "$rc" "deploy exits"
    assert_contains "$out" "cannot list ports" "clear error"
    assert_not_contains "$out" "installer-would-run" "installer not reached"
}

test_app_published_ports_reads_the_compose_project() {
    local ports
    ports=$(
        server_exec_timeout() {
            [[ "$2" == *"label=com.docker.compose.project=ntfy"* ]] || return 1
            printf '127.0.0.1:8086->80/tcp\n0.0.0.0:9000->9000/tcp, [::]:9000->9000/tcp, 9001/tcp\n'
        }
        app_published_ports ntfy
    )
    assert_eq "$(printf '8086\n9000')" "$ports"
}

# deploy_port_override USED OWN — PORT_OVERRIDE chosen by deploy.sh for a 31878 default
deploy_port_override() {
    sed -n '/^DEFAULT_PORT=/,/^# PHASE 1/p' "$REPO_ROOT/local/deploy.sh" > "$TEST_TMPDIR/phase.sh"
    printf 'PORT=31878\n' > "$TEST_TMPDIR/install.sh"
    SCRIPT_PATH="$TEST_TMPDIR/install.sh" USED="$1" OWN="$2" bash -c '
        DOMAIN="" APP_NAME=app SSH_ALIAS=test
        read_existing_app_port() { return 1; }
        msg() { :; }
        source "$1/lib/port-utils.sh"
        listening_ports() { printf "%s\n" "$USED"; }
        app_published_ports() { [ -z "$OWN" ] || printf "%s\n" "$OWN"; }
        source "$2" >/dev/null
        printf "%s" "$PORT_OVERRIDE"' bash "$REPO_ROOT" "$TEST_TMPDIR/phase.sh"
}

test_redeploy_keeps_the_port_the_app_already_holds() {
    assert_eq "" "$(deploy_port_override "$(printf '22\n31878')" 31878)" "default port held by the app itself"
}

test_redeploy_keeps_a_moved_port_the_app_already_holds() {
    assert_eq 31879 "$(deploy_port_override "$(printf '31878\n31879')" 31879)" "app stays on its moved port"
}

test_port_taken_by_another_service_moves_a_new_app() {
    assert_eq 31879 "$(deploy_port_override "$(printf '22\n31878')" "")" "next free port"
}

run_tests "$0"
