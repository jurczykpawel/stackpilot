#!/bin/bash

# Tests for system/caddy-install.sh and the sp-expose helper it writes

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

source "$TESTS_DIR/test-runner.sh"

stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$FAKE/bin/$1"
    chmod +x "$FAKE/bin/$1"
}

# sudo redirects every system path into the fake server; nothing touches the host
setup() {
    TEST_TMPDIR=$(mktemp -d)
    export FAKE="$TEST_TMPDIR"
    mkdir -p "$FAKE/bin" "$FAKE/etc/apt/sources.list.d" "$FAKE/usr/local/bin"
    stub sudo 'args=()
for arg in "$@"; do
    case "$arg" in /etc/*|/usr/*) arg="$FAKE$arg" ;; esac
    args+=("$arg")
done
exec "${args[@]}"'
    stub apt 'exit 0'
    stub apk 'exit 0'
    stub rc-update 'exit 0'
    stub curl 'echo downloaded'
    stub gpg 'cat > /dev/null'
    stub caddy '[ ! -e "$FAKE/caddy-invalid" ]'
    # caddy-dies: starting reports success, yet the service does not stay up
    stub systemctl '[ "$1" = list-unit-files ] && exit 0
[ "$1" != is-active ] || [ ! -e "$FAKE/caddy-dies" ] || exit 3
[ ! -e "$FAKE/caddy-down" ]'
    stub sleep 'exit 0'
    CADDYFILE="$FAKE/etc/caddy/Caddyfile"
}

install_caddy() {
    OUTPUT=$(env -i FAKE="$FAKE" HOME="$FAKE" PATH="$FAKE/bin:/usr/bin:/bin" TOOLBOX_LANG="${1:-en}" \
        bash "$REPO_ROOT/system/caddy-install.sh" 2>&1) && STATUS=0 || STATUS=$?
}

existing_caddyfile() {
    mkdir -p "$FAKE/etc/caddy"
    printf '%s\n' "$@" > "$CADDYFILE"
}

imports() { grep -c '^import /etc/caddy/conf.d/\*.caddy$' "$CADDYFILE" || true; }

test_runs_with_language_preset() {
    install_caddy pl
    assert_eq "0" "$STATUS" "succeeds"
    assert_contains "$OUTPUT" "Instalacja Caddy" "prints translated messages"
}

test_fresh_server_gets_managed_caddyfile() {
    install_caddy
    assert_eq "0" "$STATUS" "succeeds"
    assert_eq "1" "$(imports)" "imports conf.d"
    assert_true test -x "$FAKE/usr/local/bin/sp-expose"
}

test_package_default_caddyfile_is_replaced() {
    existing_caddyfile '# The Caddyfile is an easy way to configure your Caddy web server.' '' ':80 {' \
        '	# Set this path to your site directory.' '	root * /usr/share/caddy' '' '	file_server' \
        '	# reverse_proxy localhost:8080' '}'
    install_caddy
    assert_eq "0" "$STATUS" "succeeds"
    assert_eq "1" "$(imports)" "imports conf.d"
    assert_false grep -q usr/share/caddy "$CADDYFILE"
}

test_own_configuration_is_kept() {
    existing_caddyfile 'own.example.com {' '    reverse_proxy localhost:9000' '}'
    install_caddy
    install_caddy
    assert_eq "0" "$STATUS" "succeeds"
    assert_true grep -q 'own.example.com' "$CADDYFILE"
    assert_true grep -q 'localhost:9000' "$CADDYFILE"
    assert_eq "1" "$(imports)" "imports conf.d once"
}

test_existing_relative_import_is_not_duplicated() {
    existing_caddyfile 'import conf.d/*'
    install_caddy
    assert_eq "0" "$STATUS" "succeeds"
    assert_eq "import conf.d/*" "$(cat "$CADDYFILE")" "unchanged"
}

test_configuration_rejected_by_caddy_is_restored() {
    existing_caddyfile 'own.example.com' 'respond ok'
    touch "$FAKE/caddy-invalid"
    install_caddy
    assert_not_eq "0" "$STATUS" "fails"
    assert_contains "$OUTPUT" "left unchanged" "explains why"
    assert_eq "$(printf 'own.example.com\nrespond ok')" "$(cat "$CADDYFILE")" "unchanged"
}

test_repository_download_failure_is_an_error() {
    stub curl 'exit 22'
    install_caddy
    assert_not_eq "0" "$STATUS" "fails"
}

# sp-expose as installed, pointed at the fake server
expose() {
    sed "s|/etc/caddy|$FAKE/etc/caddy|g" "$FAKE/usr/local/bin/sp-expose" > "$FAKE/sp-expose"
    OUTPUT=$(PATH="$FAKE/bin:/usr/bin:/bin" bash "$FAKE/sp-expose" "$@" 2>&1) && STATUS=0 || STATUS=$?
}

test_expose_reports_a_working_site() {
    install_caddy
    expose app.internal 8085
    assert_eq "0" "$STATUS" "succeeds"
    assert_contains "$OUTPUT" "https://app.internal" "prints the address"
}

test_expose_fails_when_caddy_does_not_load() {
    install_caddy
    touch "$FAKE/caddy-down"
    expose app.internal 8085
    assert_not_eq "0" "$STATUS" "fails"
    assert_not_contains "$OUTPUT" "Done!" "no success message"
}

test_expose_fails_when_caddy_exits_after_start() {
    install_caddy
    touch "$FAKE/caddy-dies"
    expose app.internal 8085
    assert_not_eq "0" "$STATUS" "fails"
    assert_not_contains "$OUTPUT" "Done!" "no success message"
}

test_expose_does_not_repeat_an_http_only_site() {
    install_caddy
    expose app.internal 8085 proxy --cloudflare
    expose app.internal 8085 proxy --cloudflare
    assert_not_eq "0" "$STATUS" "second run refuses"
    assert_eq "1" "$(grep -c '^http://app.internal {$' "$FAKE/etc/caddy/conf.d/app.internal.caddy")" "one block"
}

run_tests "$0"
