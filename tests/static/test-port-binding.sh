#!/bin/bash

# StackPilot - Port Binding Validation
# Every published port starts with ${BIND_ADDR} or a literal 127.0.0.1, or is listed below with a reason.
# BIND_ADDR must be empty for Cytrus (direct routing) and 127.0.0.1: for every other domain type.
# Coolify (upstream installer), Mailstack (compose file from its own repository) and the Supabase
# compose file (downloaded; see tests/unit/test-supabase-ports.sh) have no port lines here.

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

# file|published line|reason
EXCEPTIONS='apps/wordpress/install.sh|- "6379:6379"|shared Redis, managed by the WordPress installer
apps/wordpress/redis-shared.sh|- "$address:6379:6379"|shared Redis on the Docker bridge address
apps/sellf/release-verify.sh|network_mode: host|reaches a local Supabase on localhost; listener set by the app'

# These bind to localhost for every domain type
LOCALHOST_ONLY="picoclaw social-media-generator wordpress"

# Lines of a script that publish a port: Compose "ports:" entries, host networking, docker run -p
published_lines() {
    awk '
        { sub(/^[[:space:]]+/, "") }
        /^#/ { next }
        /\\$/ { sub(/\\+$/, ""); joined = joined $0 " "; next }
        { $0 = joined $0; joined = "" }
        in_ports && /^-/ { print; next }
        in_ports && /^$/ { next }
        { in_ports = 0 }
        /^ports:$/ { in_ports = 1; next }
        /^ports:/ || /network_mode:.*host|--net(work)?[= ]host/ { print; next }
        /docker (container )?(run|create) .*[[:space:]](-p|--publish)[= ]/ { print }
    ' "$1"
}

bind_addr_for() {
    local definition
    definition=$(awk '
        /^if \[ "\$\{DOMAIN_TYPE:-\}" = "cytrus" \]/ { block = 1 }
        block { print; if ($0 == "fi") block = 0; next }
        /^BIND_ADDR=/ || /^\[ "\$\{DOMAIN_TYPE:-\}" != cytrus \]/ { print }
    ' "$1")
    env -i DOMAIN_TYPE="$2" "$BASH" -c "$definition"$'\n''printf %s "${BIND_ADDR-undefined}"'
}

echo "--- Port Binding ---"
echo ""

CHECKED=0
FAIL=0

for script in "$REPO_ROOT"/apps/*/*.sh; do
    file="${script#"$REPO_ROOT"/}"
    app=$(basename "$(dirname "$script")")

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        CHECKED=$((CHECKED + 1))
        value="${line#- }"
        value="${value#[\"\']}"
        case "$value" in
            '${BIND_ADDR}'*|127.0.0.1:*) continue ;;
        esac
        grep -qF -- "$file|$line|" <<< "$EXCEPTIONS" && continue
        FAIL=$((FAIL + 1))
        echo "  ✗ $file: $line"
    done < <(published_lines "$script")

    grep -qE '\$\{?BIND_ADDR' "$script" || continue
    for type in "" local caddy cloudflare cytrus; do
        expected="127.0.0.1:"
        if [ "$type" = cytrus ] && ! grep -qw -- "$app" <<< "$LOCALHOST_ONLY"; then expected=""; fi
        actual=$(bind_addr_for "$script" "$type")
        if [ "$actual" != "$expected" ]; then
            FAIL=$((FAIL + 1))
            echo "  ✗ $file: DOMAIN_TYPE='$type' gives BIND_ADDR='$actual', expected '$expected'"
        fi
    done
done

echo ""
echo "  Published port lines: $CHECKED, problems: $FAIL"

if [ "$CHECKED" -eq 0 ] || [ "$FAIL" -gt 0 ]; then
    echo "FAIL — use \${BIND_ADDR} (see AGENTS.md, Code Style) or add a justified exception"
    exit 1
fi
echo "PASS — all published ports follow the binding convention"
