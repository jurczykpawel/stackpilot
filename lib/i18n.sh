#!/bin/bash

# StackPilot - Internationalization (i18n) Loader
# Loads locale files with user-facing strings.
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   source "$REPO_ROOT/lib/i18n.sh"
#   # TOOLBOX_LANG is read from:
#   #   1. $TOOLBOX_LANG env variable
#   #   2. ~/.config/stackpilot/config (lang=xx)
#   #   3. fallback: "en"
#   msg "$MSG_CHECKING_APP" "$APP_NAME"
#
# Locale files: locale/en.sh, locale/pl.sh
# Convention: MSG_ prefix, SCREAMING_SNAKE_CASE

# --------------------------------------------------------------------------
# Resolve TOOLBOX_LANG
# --------------------------------------------------------------------------

_i18n_resolve_lang() {
    # 1. Env variable (highest priority)
    if [ -n "$TOOLBOX_LANG" ]; then
        echo "$TOOLBOX_LANG"
        return
    fi

    # 2. Config file
    local CONFIG_FILE="${STACKPILOT_CONFIG:-$HOME/.config/stackpilot/config}"
    if [ -f "$CONFIG_FILE" ]; then
        local LANG_FROM_CONFIG
        LANG_FROM_CONFIG=$(grep -E '^lang=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')
        if [ -n "$LANG_FROM_CONFIG" ]; then
            echo "$LANG_FROM_CONFIG"
            return
        fi
    fi

    # 3. Fallback
    echo "en"
}

# --------------------------------------------------------------------------
# Load locale
# --------------------------------------------------------------------------

_i18n_load() {
    local LANG="$1"

    # Find locale dir relative to this script or REPO_ROOT
    local LOCALE_DIR
    if [ -n "$REPO_ROOT" ]; then
        LOCALE_DIR="$REPO_ROOT/locale"
    else
        LOCALE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/locale"
    fi

    local LOCALE_FILE="$LOCALE_DIR/${LANG}.sh"

    if [ ! -f "$LOCALE_FILE" ]; then
        # Requested locale doesn't exist — fall back to English
        if [ "$LANG" != "en" ]; then
            echo "[i18n] Warning: locale '$LANG' not found, falling back to 'en'" >&2
            LOCALE_FILE="$LOCALE_DIR/en.sh"
        fi

        if [ ! -f "$LOCALE_FILE" ]; then
            echo "[i18n] Error: locale file '$LOCALE_FILE' not found!" >&2
            return 1
        fi
    fi

    # Load English first as fallback (so missing keys in other locales still work)
    local EN_FILE="$LOCALE_DIR/en.sh"
    if [ -f "$EN_FILE" ]; then
        # shellcheck disable=SC1090
        source "$EN_FILE"
    fi

    # Then load the requested locale (overrides EN keys)
    if [ "$LANG" != "en" ] && [ -f "$LOCALE_FILE" ]; then
        # shellcheck disable=SC1090
        source "$LOCALE_FILE"
    fi
}

# --------------------------------------------------------------------------
# msg() — printf-style message function
# --------------------------------------------------------------------------
# Usage:
#   msg "$MSG_DEPLOYING" "$APP_NAME"
#   msg "$MSG_SIMPLE_MESSAGE"
#
# The first argument is the format string (from locale).
# Remaining arguments are substituted via printf %s/%d/etc.

msg() {
    local FMT="$1"
    shift
    # shellcheck disable=SC2059
    printf -- "$FMT\n" "$@"
}

# msg_n() — same as msg() but without trailing newline
msg_n() {
    local FMT="$1"
    shift
    # shellcheck disable=SC2059
    printf -- "$FMT" "$@"
}

# --------------------------------------------------------------------------
# Initialize
# --------------------------------------------------------------------------

TOOLBOX_LANG="$(_i18n_resolve_lang)"
_i18n_load "$TOOLBOX_LANG"

# Export for child processes
export TOOLBOX_LANG
export -f msg 2>/dev/null
export -f msg_n 2>/dev/null
