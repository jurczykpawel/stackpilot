#!/bin/bash
# shellcheck disable=SC2034  # SP_* variables are intentional outputs for callers.

# StackPilot - Static framework detection.
#
# Exposes:
#   sp_detect_static_framework <project_dir>
#     Sets globals: SP_FRAMEWORK, SP_BUILD_CMD, SP_OUTPUT_DIR
#     Returns 0 on detection, 1 if no framework matched.
#
# Supported:
#   Astro, Next.js (static export), Hugo, Eleventy (11ty),
#   SvelteKit (static), Gatsby, Docusaurus, VitePress, MkDocs

sp_detect_static_framework() {
    local project_dir="${1:-.}"
    SP_FRAMEWORK=""
    SP_BUILD_CMD=""
    SP_OUTPUT_DIR=""

    if [ ! -d "$project_dir" ]; then
        echo "❌ Project directory not found: $project_dir" >&2
        return 1
    fi

    local abs_dir
    abs_dir="$(cd "$project_dir" && pwd)"

    pushd "$abs_dir" >/dev/null || return 1

    if compgen -G "astro.config.*" >/dev/null; then
        SP_FRAMEWORK="Astro"
        SP_BUILD_CMD="npm run build"
        SP_OUTPUT_DIR="./dist"

    elif compgen -G "next.config.*" >/dev/null; then
        if grep -E -r --include='next.config.*' "output:[[:space:]]*['\"]export['\"]" . >/dev/null 2>&1; then
            SP_FRAMEWORK="Next.js (static export)"
            SP_BUILD_CMD="npm run build"
            SP_OUTPUT_DIR="./out"
        else
            popd >/dev/null || return 1
            echo "⚠️  Detected Next.js, but \"output: 'export'\" is missing from next.config.*" >&2
            echo "   Static deployment requires static export. Add to your next.config:" >&2
            echo "" >&2
            echo "       module.exports = { output: 'export' }" >&2
            echo "" >&2
            return 1
        fi

    elif { [ -f "hugo.toml" ] || [ -f "hugo.yaml" ] || [ -f "hugo.yml" ] \
        || [ -f "config.toml" ] || [ -f "config.yaml" ] || [ -f "config.yml" ]; } \
        && [ -d "content" ]; then
        SP_FRAMEWORK="Hugo"
        SP_BUILD_CMD="hugo --minify"
        SP_OUTPUT_DIR="./public"

    elif [ -f ".eleventy.js" ] || compgen -G "eleventy.config.*" >/dev/null; then
        SP_FRAMEWORK="Eleventy (11ty)"
        SP_BUILD_CMD="npx @11ty/eleventy"
        SP_OUTPUT_DIR="./_site"

    elif compgen -G "svelte.config.*" >/dev/null; then
        SP_FRAMEWORK="SvelteKit (static)"
        SP_BUILD_CMD="npm run build"
        SP_OUTPUT_DIR="./build"

    elif compgen -G "gatsby-config.*" >/dev/null; then
        SP_FRAMEWORK="Gatsby"
        SP_BUILD_CMD="npm run build"
        SP_OUTPUT_DIR="./public"

    elif compgen -G "docusaurus.config.*" >/dev/null; then
        SP_FRAMEWORK="Docusaurus"
        SP_BUILD_CMD="npm run build"
        SP_OUTPUT_DIR="./build"

    elif [ -d ".vitepress" ]; then
        SP_FRAMEWORK="VitePress"
        SP_BUILD_CMD="npm run docs:build"
        SP_OUTPUT_DIR="./.vitepress/dist"

    elif [ -f "mkdocs.yml" ] || [ -f "mkdocs.yaml" ]; then
        SP_FRAMEWORK="MkDocs"
        SP_BUILD_CMD="mkdocs build"
        SP_OUTPUT_DIR="./site"

    else
        popd >/dev/null || return 1
        return 1
    fi

    popd >/dev/null || return 1
    return 0
}
