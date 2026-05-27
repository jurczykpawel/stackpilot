#!/bin/bash
# StackPilot - Build per-app installer scripts for stackpilot.techskills.academy
#
# Iterates apps/*/ and renders installers/template.sh for each, dropping the
# results into the output directory alongside the existing landing page files.
# Also writes a _headers file so Cloudflare Pages serves the extensionless
# installer files as text/plain (and keeps the landing as text/html).
#
# Usage:
#   ./installers/build.sh <output_dir>
#
# Example:
#   ./installers/build.sh ../static-sites/stackpilot.techskills.academy

set -euo pipefail

OUT="${1:?Usage: $0 <output_dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/installers/template.sh"
APPS_DIR="$ROOT/apps"

# Filenames already used by the landing site — never overwrite these.
RESERVED=(index en pl style micro logo fonts robots.txt sitemap.xml llms.txt _headers _redirects _routes.json)

is_reserved() {
    local name="$1"
    for r in "${RESERVED[@]}"; do
        [ "$name" = "$r" ] && return 0
    done
    return 1
}

[ -f "$TEMPLATE" ] || { echo "Error: template not found at $TEMPLATE" >&2; exit 1; }
[ -d "$APPS_DIR" ] || { echo "Error: apps dir not found at $APPS_DIR" >&2; exit 1; }
mkdir -p "$OUT"

# Clean up stale installer files (extensionless top-level files in OUT).
# Landing files all have extensions (.html, .css, .js, .svg). Generated
# installer files never do. This makes renamed/removed apps drop out cleanly.
while IFS= read -r -d '' stale; do
    name=$(basename "$stale")
    if ! is_reserved "$name"; then
        rm -f "$stale"
    fi
done < <(find "$OUT" -maxdepth 1 -type f ! -name "*.*" -print0)

apps=()
for dir in "$APPS_DIR"/*/; do
    app=$(basename "$dir")
    [ -f "$dir/install.sh" ] || continue
    if is_reserved "$app"; then
        echo "  skip (reserved name): $app" >&2
        continue
    fi
    sed "s/__APP__/$app/g" "$TEMPLATE" > "$OUT/$app"
    apps+=("$app")
done

# _headers: set content-type per file. Cloudflare Pages matches paths exactly.
{
    echo "/"
    echo "  Content-Type: text/html; charset=utf-8"
    echo ""
    for app in "${apps[@]}"; do
        echo "/$app"
        echo "  Content-Type: text/plain; charset=utf-8"
        echo "  Cache-Control: public, max-age=300"
        echo "  X-Content-Type-Options: nosniff"
        echo ""
    done
} > "$OUT/_headers"

echo "Generated ${#apps[@]} installers in $OUT/"
echo "Apps: ${apps[*]}"
