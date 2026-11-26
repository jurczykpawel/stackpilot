#!/bin/bash

# Tests for domain configuration through Caddy (caddy and cloudflare domain types)

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

export TOOLBOX_LANG=en
source "$REPO_ROOT/lib/i18n.sh"
source "$REPO_ROOT/lib/cli-parser.sh"
source "$REPO_ROOT/lib/server-exec.sh"
source "$REPO_ROOT/lib/domain-setup.sh"

_ON_SERVER=true

# A fake server: its own PATH, /etc/caddy and /tmp. `bash -s` stands for the
# Caddy installer; INSTALL_RESULT decides what it does.
server_exec() {
    if [ "$1" = "bash -s" ]; then
        cat > "$FAKE/installer-input"
        echo run >> "$FAKE/installer.log"
        case "$INSTALL_RESULT" in
            ok) add_caddy ;;
            fail) echo "E: Unable to locate package caddy"; return 100 ;;
            incomplete) ;;
        esac
        return 0
    fi
    # /tmp first: on Linux $FAKE is itself under /tmp/, so it must be inserted afterwards
    local cmd="${1//\/tmp\//$FAKE/tmp/}"
    cmd="${cmd//\/etc\/caddy/$FAKE/etc/caddy}"
    PATH="$FAKE/bin" "$FAKE/bin/bash" -c "$cmd"
}

stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$FAKE/bin/$1"
    chmod +x "$FAKE/bin/$1"
}

add_caddy() {
    stub caddy 'exit 0'
    stub sp-expose 'echo "$*" >> "$FAKE/sp-expose.log"
[ ! -e "$FAKE/sp-expose-refuses" ] || exit 1
printf "%s {\n}\n" "$1" > "$FAKE/etc/caddy/conf.d/$1.caddy"'
}

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export FAKE="$TEST_TMPDIR"
    mkdir -p "$FAKE/bin" "$FAKE/etc/caddy/conf.d" "$FAKE/tmp"
    local tool
    for tool in bash cat grep head id ls rm sort xargs; do
        ln -s "$(command -v "$tool")" "$FAKE/bin/$tool"
    done
    stub sudo 'exec "$@"'
    # caddy-dies: starting reports success, yet the service does not stay up
    stub systemctl '[ "$1" != is-active ] || [ ! -e "$FAKE/caddy-dies" ] || exit 3
[ ! -e "$FAKE/caddy-down" ]'
    stub sleep 'exit 0'
    # Nothing listens on ports 80 and 443
    stub ss 'exit 0'
    INSTALL_RESULT=ok
    DOMAIN="app.internal"
    DOMAIN_TYPE="caddy"
    DRY_RUN=false
}

configure() { OUTPUT=$(configure_domain 8085 vps 2>&1) && STATUS=0 || STATUS=$?; }
calls() { cat "$FAKE/$1" 2>/dev/null || true; }
site() { printf '%s {\n    reverse_proxy localhost:8085\n}\n' "$1" > "$FAKE/etc/caddy/conf.d/$1.caddy"; }

test_fresh_server_gets_caddy_and_the_site() {
    configure
    assert_eq "0" "$STATUS" "succeeds"
    assert_eq "run" "$(calls installer.log)" "installer ran once"
    assert_contains "$(cat "$FAKE/installer-input")" "sp-expose" "installer is system/caddy-install.sh"
    assert_eq "app.internal 8085 proxy" "$(calls sp-expose.log)" "site exposed"
    assert_contains "$OUTPUT" "Domain configured: https://app.internal" "reports success"
}

test_existing_caddy_is_not_reinstalled() {
    add_caddy
    configure
    assert_eq "0" "$STATUS" "succeeds"
    assert_eq "" "$(calls installer.log)" "installer not run"
}

test_installer_failure_is_an_error() {
    INSTALL_RESULT=fail
    configure
    assert_not_eq "0" "$STATUS" "fails"
    assert_contains "$OUTPUT" "Unable to locate package caddy" "shows the installer error"
    assert_contains "$OUTPUT" "Caddy installation failed" "says what failed"
    assert_not_contains "$OUTPUT" "Domain configured" "no success message"
}

test_installer_leaving_no_tools_is_an_error() {
    INSTALL_RESULT=incomplete
    configure
    assert_not_eq "0" "$STATUS" "fails"
    assert_not_contains "$OUTPUT" "Domain configured" "no success message"
}

test_refused_site_is_an_error() {
    add_caddy
    touch "$FAKE/sp-expose-refuses"
    configure
    assert_not_eq "0" "$STATUS" "fails"
    assert_not_contains "$OUTPUT" "Domain configured" "no success message"
}

test_already_configured_site_succeeds() {
    add_caddy
    touch "$FAKE/sp-expose-refuses"
    site app.internal
    configure
    assert_eq "0" "$STATUS" "succeeds"
    assert_contains "$OUTPUT" "already configured" "says it was configured"
}

test_http_only_site_counts_as_configured() {
    add_caddy
    touch "$FAKE/sp-expose-refuses"
    printf 'http://app.internal {\n}\n' > "$FAKE/etc/caddy/conf.d/app.internal.caddy"
    configure
    assert_eq "0" "$STATUS" "succeeds"
}

test_similar_domain_does_not_count_as_configured() {
    add_caddy
    touch "$FAKE/sp-expose-refuses"
    site myapp.internal
    site app-internal
    configure
    assert_not_eq "0" "$STATUS" "fails"
}

test_caddy_not_running_is_an_error() {
    add_caddy
    touch "$FAKE/caddy-down"
    configure
    assert_not_eq "0" "$STATUS" "fails"
    assert_not_contains "$OUTPUT" "Domain configured" "no success message"
}

test_caddy_exiting_after_start_is_an_error() {
    add_caddy
    touch "$FAKE/caddy-dies"
    configure
    assert_not_eq "0" "$STATUS" "fails"
    assert_not_contains "$OUTPUT" "Domain configured" "no success message"
}

test_static_site_is_served_from_its_directory() {
    echo /var/www/page > "$FAKE/tmp/page_webroot"
    configure
    assert_eq "0" "$STATUS" "succeeds"
    assert_eq "app.internal /var/www/page static" "$(calls sp-expose.log)" "file server"
    assert_false test -e "$FAKE/tmp/page_webroot"
}

# No DNS or Cloudflare API calls: those scripts are looked up next to SCRIPT_DIR
configure_cloudflare() {
    DOMAIN_TYPE="cloudflare"
    local SCRIPT_DIR="$FAKE/nowhere/lib"
    mkdir -p "$SCRIPT_DIR"
    configure
}

test_cloudflare_path_installs_caddy() {
    configure_cloudflare
    assert_eq "0" "$STATUS" "succeeds"
    assert_eq "run" "$(calls installer.log)" "installer ran once"
}

test_cloudflare_path_installer_failure_is_an_error() {
    INSTALL_RESULT=fail
    configure_cloudflare
    assert_not_eq "0" "$STATUS" "fails"
    assert_contains "$OUTPUT" "Caddy installation failed" "says what failed"
}

run_tests "$0"
