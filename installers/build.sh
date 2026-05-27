#!/bin/bash
# StackPilot - Build installer/setup script endpoints for stackpilot.techskills.academy
#
# Generates three kinds of files in the output directory:
#   1. /install            — verbatim copy of system/bootstrap.sh
#   2. /<setup-alias>      — setup-template.sh rendered per local/setup-*.sh script
#                            (cloudflare, sellf-config, ...)
#   3. /<app>              — template.sh rendered per apps/<app>/install.sh
#
# Also writes _headers so Cloudflare Pages serves the extensionless files as
# text/plain (and keeps the landing as text/html).
#
# Usage:
#   ./installers/build.sh <output_dir>

set -euo pipefail

OUT="${1:?Usage: $0 <output_dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_TEMPLATE="$ROOT/installers/template.sh"
SETUP_TEMPLATE="$ROOT/installers/setup-template.sh"
BOOTSTRAP_SRC="$ROOT/system/bootstrap.sh"
APPS_DIR="$ROOT/apps"

# Setup script aliases — "endpoint-name:local-script". Edit here to expose more.
SETUP_SCRIPTS="cloudflare:setup-cloudflare.sh sellf-config:setup-sellf-config.sh"

# Filenames already used by the landing site or by this script — never overwrite.
RESERVED=(index en pl style micro logo fonts robots.txt sitemap.xml llms.txt _headers _redirects _routes.json install)
# Setup aliases are also reserved (apps can't shadow them).
for pair in $SETUP_SCRIPTS; do
    RESERVED+=("${pair%%:*}")
done

is_reserved() {
    local name="$1"
    for r in "${RESERVED[@]}"; do
        [ "$name" = "$r" ] && return 0
    done
    return 1
}

[ -f "$APP_TEMPLATE" ] || { echo "Error: app template not found at $APP_TEMPLATE" >&2; exit 1; }
[ -f "$SETUP_TEMPLATE" ] || { echo "Error: setup template not found at $SETUP_TEMPLATE" >&2; exit 1; }
[ -f "$BOOTSTRAP_SRC" ] || { echo "Error: bootstrap source not found at $BOOTSTRAP_SRC" >&2; exit 1; }
[ -d "$APPS_DIR" ] || { echo "Error: apps dir not found at $APPS_DIR" >&2; exit 1; }
mkdir -p "$OUT"

# Clean up stale endpoint files (extensionless top-level files in OUT) that
# are not in the current reserved set. Landing files all have extensions, so
# this cleanly removes renamed/dropped apps without touching the landing.
while IFS= read -r -d '' stale; do
    name=$(basename "$stale")
    if ! is_reserved "$name"; then
        rm -f "$stale"
    fi
done < <(find "$OUT" -maxdepth 1 -type f ! -name "*.*" -print0)

# 1. /install — copy bootstrap verbatim.
cp "$BOOTSTRAP_SRC" "$OUT/install"

# 2. /<setup-alias> — render setup-template for each setup-*.sh script.
setup_aliases=()
for pair in $SETUP_SCRIPTS; do
    alias="${pair%%:*}"
    script="${pair##*:}"
    if [ ! -f "$ROOT/local/$script" ]; then
        echo "  skip (missing local/$script): $alias" >&2
        continue
    fi
    sed -e "s/__NAME__/$alias/g" -e "s/__SCRIPT__/$script/g" "$SETUP_TEMPLATE" > "$OUT/$alias"
    setup_aliases+=("$alias")
done

# 3. /<app> — render app installer template for each apps/*/install.sh.
apps=()
for dir in "$APPS_DIR"/*/; do
    app=$(basename "$dir")
    [ -f "$dir/install.sh" ] || continue
    if is_reserved "$app"; then
        echo "  skip (reserved name): $app" >&2
        continue
    fi
    sed "s/__APP__/$app/g" "$APP_TEMPLATE" > "$OUT/$app"
    apps+=("$app")
done

# _headers: set content-type per file. Cloudflare Pages matches paths exactly.
{
    echo "/"
    echo "  Content-Type: text/html; charset=utf-8"
    echo ""
    echo "/install"
    echo "  Content-Type: text/plain; charset=utf-8"
    echo "  Cache-Control: public, max-age=300"
    echo "  X-Content-Type-Options: nosniff"
    echo ""
    for alias in "${setup_aliases[@]}"; do
        echo "/$alias"
        echo "  Content-Type: text/plain; charset=utf-8"
        echo "  Cache-Control: public, max-age=300"
        echo "  X-Content-Type-Options: nosniff"
        echo ""
    done
    for app in "${apps[@]}"; do
        echo "/$app"
        echo "  Content-Type: text/plain; charset=utf-8"
        echo "  Cache-Control: public, max-age=300"
        echo "  X-Content-Type-Options: nosniff"
        echo ""
    done
} > "$OUT/_headers"

echo "Generated /install + ${#setup_aliases[@]} setup aliases + ${#apps[@]} app installers in $OUT/"
echo "Setup aliases: ${setup_aliases[*]}"
echo "Apps: ${apps[*]}"
