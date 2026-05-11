#!/bin/bash

# StackPilot - Deploy Static Site
# Auto-detects a static site generator in the project directory, runs the build,
# and deploys the output via add-static-hosting.sh.
#
# Supported (auto-detected):
#   Astro, Next.js (static export), Hugo, Eleventy (11ty),
#   SvelteKit (static), Gatsby, Docusaurus, VitePress, MkDocs
#
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   ./local/deploy-static.sh DOMAIN [SSH_ALIAS] [PROJECT_DIR]
#
# Examples:
#   cd my-astro-site
#   ./local/deploy-static.sh my-site.com vps
#
#   ./local/deploy-static.sh my-site.com mikrus ./my-astro-site

set -e

DOMAIN="$1"
SSH_ALIAS="${2:-vps}"
PROJECT_DIR="${3:-.}"

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "--help" ] || [ "$DOMAIN" = "-h" ]; then
    echo "Usage: $0 DOMAIN [SSH_ALIAS] [PROJECT_DIR]"
    echo ""
    echo "Auto-detects framework, builds the project, and deploys via add-static-hosting.sh."
    echo ""
    echo "Supported frameworks (auto-detected):"
    echo "  Astro, Next.js (static export), Hugo, Eleventy,"
    echo "  SvelteKit (static), Gatsby, Docusaurus, VitePress, MkDocs"
    echo ""
    echo "Examples:"
    echo "  cd my-astro-site"
    echo "  $0 my-site.com vps"
    echo ""
    echo "  $0 my-site.com mikrus ./my-astro-site"
    echo ""
    echo "Defaults:"
    echo "  SSH_ALIAS:    vps"
    echo "  PROJECT_DIR:  . (current directory)"
    echo ""
    echo "After auto-detection, runs the framework's build command and then calls"
    echo "add-static-hosting.sh DOMAIN SSH_ALIAS OUTPUT_DIR (handles upload, Caddy, SSL, DNS)."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/validation.sh"
source "$SCRIPT_DIR/../lib/framework-detect.sh"

if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$SCRIPT_DIR/../lib/i18n.sh"
fi

sp_validate_domain "$DOMAIN" || exit 1
sp_validate_ssh_alias "$SSH_ALIAS" || exit 1

if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ Project directory not found: $PROJECT_DIR"
    exit 1
fi

ABS_PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
cd "$ABS_PROJECT_DIR"

if ! sp_detect_static_framework "$ABS_PROJECT_DIR"; then
    echo "❌ Could not detect a static site framework in: $ABS_PROJECT_DIR"
    echo ""
    echo "Supported: Astro, Next.js (static export), Hugo, Eleventy, SvelteKit (static),"
    echo "           Gatsby, Docusaurus, VitePress, MkDocs"
    echo ""
    echo "If your project uses one of these but with a non-standard config filename,"
    echo "build manually and then call add-static-hosting.sh directly:"
    echo ""
    echo "    ./local/add-static-hosting.sh $DOMAIN $SSH_ALIAS ./your-output-dir"
    exit 1
fi

FRAMEWORK="$SP_FRAMEWORK"
BUILD_CMD="$SP_BUILD_CMD"
OUTPUT_DIR="$SP_OUTPUT_DIR"

echo ""
echo "🚀 StackPilot — Deploy Static Site"
echo ""
echo "   Framework:    $FRAMEWORK"
echo "   Build cmd:    $BUILD_CMD"
echo "   Output dir:   $OUTPUT_DIR"
echo "   Domain:       $DOMAIN"
echo "   Server:       $SSH_ALIAS"
echo "   Project:      $ABS_PROJECT_DIR"
echo ""

echo "📦 Building (this can take 30s–2min)..."
if ! eval "$BUILD_CMD"; then
    echo "❌ Build failed"
    exit 1
fi

if [ ! -d "$OUTPUT_DIR" ]; then
    echo "❌ Build did not produce expected output directory: $OUTPUT_DIR"
    echo "   Check your build configuration. Some frameworks allow customizing the output path."
    exit 1
fi

echo "✅ Build complete"
echo ""

"$SCRIPT_DIR/add-static-hosting.sh" "$DOMAIN" "$SSH_ALIAS" "$OUTPUT_DIR"
