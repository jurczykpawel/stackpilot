# shellcheck shell=bash
# In-memory keystore backend for unit tests. File-backed (in tmp dir) so it
# works on macOS default bash 3.2 (no associative arrays available there).

mock_backend_reset() {
    if [ -n "${_MOCK_DIR:-}" ] && [ -d "$_MOCK_DIR" ]; then
        rm -rf "$_MOCK_DIR"
    fi
    _MOCK_DIR=$(mktemp -d)
    export _MOCK_DIR
}

_backend_available() { return 0; }

_backend_set() {
    local name="$1" value="$2"
    [ -n "${_MOCK_DIR:-}" ] || mock_backend_reset
    printf '%s' "$value" > "$_MOCK_DIR/$name"
}

_backend_get() {
    local name="$1"
    [ -n "${_MOCK_DIR:-}" ] || return 1
    [ -f "$_MOCK_DIR/$name" ] || return 1
    cat "$_MOCK_DIR/$name"
}

_backend_has() {
    local name="$1"
    [ -n "${_MOCK_DIR:-}" ] || return 1
    [ -f "$_MOCK_DIR/$name" ]
}

_backend_rm() {
    local name="$1"
    [ -n "${_MOCK_DIR:-}" ] || return 0
    rm -f "$_MOCK_DIR/$name"
    return 0
}

_backend_list() {
    [ -n "${_MOCK_DIR:-}" ] || return 0
    [ -d "$_MOCK_DIR" ] || return 0
    local f name
    for f in "$_MOCK_DIR"/*; do
        [ -f "$f" ] || continue
        name="${f##*/}"
        printf '%s\n' "$name"
    done
}

_backend_id() { printf 'mock'; }
