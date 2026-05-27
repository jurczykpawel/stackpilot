# Shared helpers for wizards.

# emit_error CODE PROVIDER KEY DETAIL HINT
# Prints the STACKPILOT_ERR contract line to stderr.
emit_error() {
    local code="$1" provider="$2" key="$3" detail="$4" hint="$5"
    printf 'STACKPILOT_ERR code=%s provider=%s key=%s detail="%s" hint="%s"\n' \
        "$code" "$provider" "$key" "$detail" "$hint" >&2
}

# open_browser URL
# Best-effort browser open. Always returns 0; falls back to printing URL.
open_browser() {
    local url="$1"
    if command -v open >/dev/null 2>&1; then
        open "$url" 2>/dev/null || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" 2>/dev/null || true
    elif command -v start >/dev/null 2>&1; then
        start "$url" 2>/dev/null || true
    else
        echo "Open this URL manually: $url"
    fi
}

# prompt_secret PROMPT
# Reads a secret without echoing. Echoes value to stdout.
prompt_secret() {
    local prompt="$1"
    local val
    if [ -t 0 ]; then
        read -r -s -p "$prompt" val
    else
        read -r -s -p "$prompt" val < /dev/tty 2>/dev/tty
    fi
    echo >&2
    printf '%s' "$val"
}

# prompt_continue PROMPT
# Waits for Enter, ignores input.
prompt_continue() {
    local prompt="$1"
    if [ -t 0 ]; then
        read -r -p "$prompt" _
    else
        read -r -p "$prompt" _ < /dev/tty 2>/dev/tty
    fi
}

# print_step N TOTAL TITLE
print_step() {
    local n="$1" total="$2" title="$3"
    printf '\n  [%s/%s] %s\n' "$n" "$total" "$title"
}
