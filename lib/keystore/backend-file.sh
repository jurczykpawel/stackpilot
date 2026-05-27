# Plain-file keystore backend. Fallback when no OS keystore is available.

: "${STACKPILOT_KEYSTORE_FILE_DIR:=$HOME/.config/stackpilot/keys}"

_backend_id() { printf 'file'; }

_backend_available() {
    [ -n "${HOME:-}" ]
}

_backend_warn_once() {
    if [ -n "${STACKPILOT_KEYSTORE_FILE_ACK:-}" ]; then return 0; fi
    if [ -n "${_STACKPILOT_KEYSTORE_FILE_WARNED:-}" ]; then return 0; fi
    export _STACKPILOT_KEYSTORE_FILE_WARNED=1
    cat >&2 <<EOF

⚠  Using plain-file keystore — keys stored unencrypted at:
    $STACKPILOT_KEYSTORE_FILE_DIR

   Reason: no OS keystore detected (macOS Keychain / libsecret).
   File permissions: 0600 (owner read/write only).
   To upgrade: see docs/keystore.md
   To suppress this warning: export STACKPILOT_KEYSTORE_FILE_ACK=1

EOF
}

_backend_ensure_dir() {
    if [ ! -d "$STACKPILOT_KEYSTORE_FILE_DIR" ]; then
        mkdir -p "$STACKPILOT_KEYSTORE_FILE_DIR" || return 1
        chmod 700 "$STACKPILOT_KEYSTORE_FILE_DIR" || return 1
    fi
    return 0
}

_backend_set() {
    local name="$1" value="$2"
    _backend_warn_once
    _backend_ensure_dir || return 1
    local f="$STACKPILOT_KEYSTORE_FILE_DIR/$name"
    local tmp="$f.tmp.$$"
    printf '%s' "$value" > "$tmp" || return 1
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    return 0
}

_backend_get() {
    local name="$1"
    local f="$STACKPILOT_KEYSTORE_FILE_DIR/$name"
    [ -f "$f" ] || return 1
    cat "$f"
}

_backend_has() {
    local name="$1"
    [ -f "$STACKPILOT_KEYSTORE_FILE_DIR/$name" ]
}

_backend_rm() {
    local name="$1"
    rm -f "$STACKPILOT_KEYSTORE_FILE_DIR/$name"
    return 0
}

_backend_list() {
    [ -d "$STACKPILOT_KEYSTORE_FILE_DIR" ] || return 0
    local f name
    for f in "$STACKPILOT_KEYSTORE_FILE_DIR"/*; do
        [ -f "$f" ] || continue
        name="${f##*/}"
        case "$name" in
            *.tmp.*) continue ;;
            .*) continue ;;
        esac
        printf '%s\n' "$name"
    done
}
