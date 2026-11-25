#!/bin/bash
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! grep -q '^install_docker_for_distribution()' "$ROOT/system/docker-setup.sh"; then
    echo 'FAIL: distribution installer entry point is missing'
    exit 1
fi
source "$ROOT/system/docker-setup.sh"
DIR=$(mktemp -d)
trap 'rm -r "$DIR"' EXIT
curl() {
    printf '%s\n' "$*" >> "$DIR/curl"
    if [ "${DOWNLOAD_FAIL:-0}" = 1 ]; then return 22; fi
    local destination='' previous=''
    for argument in "$@"; do
        [ "$previous" = -o ] && destination="$argument"
        previous="$argument"
    done
    if [ -n "$destination" ]; then printf 'vendor installer\n' > "$destination"; else printf 'provider installer\n'; fi
}
bash() {
    printf '%s\n' "$*" >> "$DIR/bash"
    if [ -n "${1:-}" ]; then test -s "$1"; fi
    return "${INSTALL_FAIL:-0}"
}
install_docker_for_distribution debian
grep -q 'https://get.docker.com' "$DIR/curl"
grep -q -- '-fsSL' "$DIR/curl"
test -s "$DIR/bash"
old_calls=$(wc -l < "$DIR/bash")
if DOWNLOAD_FAIL=1 install_docker_for_distribution debian; then echo 'FAIL: download error accepted'; exit 1; fi
test "$(wc -l < "$DIR/bash")" = "$old_calls"
if INSTALL_FAIL=23 install_docker_for_distribution debian; then echo 'FAIL: installation error accepted'; exit 1; fi
install_docker_for_distribution ubuntu
grep -q 'unkn0w/noobs/main/scripts/chce_dockera.sh' "$DIR/curl"
piped_output=$({ printf 'docker_setup_main() { printf called; }\n'; sed -n '/^if \[\[ /,$p' "$ROOT/system/docker-setup.sh"; } | command bash -s)
test "$piped_output" = called || { echo 'FAIL: piped setup did not run'; exit 1; }
echo 'PASS: Debian, Ubuntu, errors, and piped execution' 
