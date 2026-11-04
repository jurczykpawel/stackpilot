#!/bin/bash
# Server part of the Mailstack installer, with Docker, systemd and the network mocked.
set -e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/test-runner.sh"
ORIGINAL_PATH=$PATH

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export TEST_TMPDIR STACK_DIR="$TEST_TMPDIR/stacks/mailstack-test" CALL_LOG="$TEST_TMPDIR/calls"
    export MAILSTACK_SBIN="$TEST_TMPDIR/sbin" MAILSTACK_UNIT_DIR="$TEST_TMPDIR/units" MOCK_FAIL=""
    mkdir -p "$TEST_TMPDIR/bin" "$MAILSTACK_SBIN" "$MAILSTACK_UNIT_DIR" "$STACK_DIR/secrets/panel" "$STACK_DIR/secrets/tunnel" "$STACK_DIR/secrets/egress"
    printf 'services: {}\n' > "$STACK_DIR/compose.yml"
    printf '#!/bin/sh\necho "firewall $*" >> "$CALL_LOG"\n[ "$MOCK_FAIL" != firewall ]\n' > "$STACK_DIR/egress-firewall.sh"
    printf 'COMPOSE_PROFILES=production\nPANEL_ORIGIN=https://panel.example.com\nEGRESS_DENY_ZONES=example.net\n' > "$STACK_DIR/.env"
    printf 'tok' > "$STACK_DIR/secrets/tunnel/token"
    for cmd in docker systemctl; do
        printf '#!/bin/bash\necho "%s $*" >> "$CALL_LOG"\n[ -z "$MOCK_FAIL" ] || [[ "%s $*" != *"$MOCK_FAIL"* ]]\n' "$cmd" "$cmd" > "$TEST_TMPDIR/bin/$cmd"
    done
    printf '#!/bin/bash\ncase "$1" in chown) echo "chown $*" >> "$CALL_LOG"; exit 0;; esac\n"$@"\n' > "$TEST_TMPDIR/bin/sudo"
    cat > "$TEST_TMPDIR/bin/curl" <<'MOCK'
#!/bin/bash
case "$*" in *-4*) printf 'fl=1\nip=203.0.113.7\nts=1\n' ;; *-6*) printf 'ip=2001:db8:1::7\n' ;; esac
MOCK
    printf '#!/bin/bash\nprintf "2: eth0    inet 192.0.2.10/24 brd x scope global eth0\\n2: eth0    inet6 2001:db8:1::7/64 scope global\\n"\n' > "$TEST_TMPDIR/bin/ip"
    chmod +x "$TEST_TMPDIR/bin/"*
    export PATH="$TEST_TMPDIR/bin:$ORIGINAL_PATH"
}
teardown() {
    PATH=$ORIGINAL_PATH
    rm -rf "$TEST_TMPDIR"
    unset STACK_DIR CALL_LOG MAILSTACK_SBIN MAILSTACK_UNIT_DIR MOCK_FAIL MAILSTACK_SERVICES MAILSTACK_ACTION
}
install_with() { env MAILSTACK_SERVICES="$1" MAILSTACK_ACTION="${2:-install}" bash "$REPO_ROOT/apps/mailstack/install.sh" 2>&1; }

test_refuses_without_prepared_stack() {
    rm "$STACK_DIR/compose.yml"
    local out code=0
    out=$(install_with "api") || code=$?
    assert_eq "1" "$code" "exit code"
    assert_contains "$out" "./local/deploy.sh mailstack" "points to the local deploy command"
}

test_profile_c_builds_and_starts_without_firewall() {
    install_with "api panel cloudflared backup" >/dev/null
    local calls; calls=$(cat "$CALL_LOG")
    assert_contains "$calls" "compose -p mailstack-test" "named project"
    assert_contains "$calls" "build api panel backup" "builds only services with a build"
    assert_contains "$calls" "up -d --wait --wait-timeout 180 api panel cloudflared backup" "starts the profile services"
    assert_not_contains "$calls" "firewall" "no egress firewall in profile c"
    assert_true test -s "$STACK_DIR/secrets/panel/tls.key"
    assert_contains "$(openssl x509 -in "$STACK_DIR/secrets/panel/tls.crt" -noout -ext subjectAltName 2>/dev/null)" "panel.example.com" "certificate names the panel host"
    assert_eq "600" "$(stat -f %Lp "$STACK_DIR/secrets/panel/tls.key" 2>/dev/null || stat -c %a "$STACK_DIR/secrets/panel/tls.key")" "key mode"
}

test_rerun_keeps_tls_and_does_not_duplicate_deny_list() {
    install_with "cloudflared egress backup" >/dev/null
    install_with "panel cloudflared egress backup" >/dev/null
    local before; before=$(cat "$STACK_DIR/secrets/panel/tls.key")
    install_with "panel cloudflared egress backup" >/dev/null
    assert_eq "$before" "$(cat "$STACK_DIR/secrets/panel/tls.key")" "TLS key unchanged"
    assert_eq "1" "$(grep -c '^EGRESS_DENY_CIDRS=' "$STACK_DIR/.env")" "one deny list"
}

test_profile_a_installs_firewall_with_host_addresses_before_compose() {
    install_with "cloudflared egress backup" >/dev/null
    assert_contains "$(grep '^EGRESS_DENY_CIDRS=' "$STACK_DIR/.env")" "203.0.113.7/32" "public IPv4 from trace"
    assert_contains "$(grep '^EGRESS_DENY_CIDRS=' "$STACK_DIR/.env")" "2001:db8:1::7/128" "global IPv6"
    assert_contains "$(grep '^EGRESS_DENY_CIDRS=' "$STACK_DIR/.env")" "192.0.2.10/32" "interface IPv4"
    assert_eq "1" "$(grep '^EGRESS_DENY_CIDRS=' "$STACK_DIR/.env" | tr ',' '\n' | grep -c '2001:db8:1::7/128')" "addresses deduplicated"
    assert_contains "$(cat "$MAILSTACK_UNIT_DIR/mailstack-egress-firewall.service")" "EnvironmentFile=$STACK_DIR/.env" "unit reads this stack"
    assert_contains "$(cat "$CALL_LOG")" "systemctl enable mailstack-egress-firewall.service" "unit enabled"
    local first_fw first_up
    first_fw=$(grep -n 'systemctl restart mailstack-egress-firewall' "$CALL_LOG" | head -1 | cut -d: -f1)
    first_up=$(grep -n ' up -d' "$CALL_LOG" | head -1 | cut -d: -f1)
    assert_true test $first_fw -lt $first_up
    assert_not_contains "$(cat "$CALL_LOG")" "build cloudflared" "cloudflared is pulled"
}

test_firewall_failure_stops_before_compose() {
    export MOCK_FAIL="systemctl restart"
    local code=0
    install_with "cloudflared egress backup" >/dev/null || code=$?
    assert_not_eq "0" "$code" "fails"
    assert_not_contains "$(cat "$CALL_LOG")" " up -d" "compose not started"
}

test_refuses_firewall_unit_of_another_stack() {
    printf '[Service]\nEnvironmentFile=/opt/stacks/other/.env\n' > "$MAILSTACK_UNIT_DIR/mailstack-egress-firewall.service"
    local out code=0
    out=$(install_with "cloudflared egress backup") || code=$?
    assert_not_eq "0" "$code" "fails"
    assert_contains "$out" "/opt/stacks/other" "names the other stack"
    assert_not_contains "$(cat "$CALL_LOG" 2>/dev/null)" " up -d" "compose not started"
}

test_uninstall_removes_stack_firewall_and_is_repeatable() {
    install_with "cloudflared egress backup" >/dev/null
    install_with "" uninstall >/dev/null
    local calls; calls=$(cat "$CALL_LOG")
    assert_contains "$calls" "down -v --rmi local --remove-orphans" "volumes and local images removed"
    assert_contains "$calls" "firewall remove" "chains removed"
    assert_false test -e "$MAILSTACK_UNIT_DIR/mailstack-egress-firewall.service"
    assert_false test -e "$MAILSTACK_SBIN/mailstack-egress-firewall"
    assert_false test -e "$STACK_DIR"
    local code=0
    install_with "" uninstall >/dev/null || code=$?
    assert_eq "0" "$code" "second uninstall succeeds"
}

run_tests "$0"
