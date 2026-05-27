# shellcheck shell=bash
# macOS Keychain backend using `security` CLI.
# ACL: -T /usr/bin/security so only security CLI can read silently (no popups
# during routine operations). Keychain Access.app still prompts on "Show password".

: "${STACKPILOT_KEYCHAIN_SERVICE:=stackpilot}"

_backend_id() { printf 'keychain'; }

_backend_available() {
    [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1
}

_backend_set() {
    local name="$1" value="$2"
    security add-generic-password \
        -U \
        -a "$name" \
        -s "$STACKPILOT_KEYCHAIN_SERVICE" \
        -w "$value" \
        -T /usr/bin/security >/dev/null 2>&1
}

_backend_get() {
    local name="$1"
    SECURITY_AUTH_INTERACTION_ALLOWED=NO \
        security find-generic-password -s "$STACKPILOT_KEYCHAIN_SERVICE" -a "$name" -w 2>/dev/null
    local rc=$?
    [ $rc -eq 0 ] && return 0
    return 1
}

_backend_has() {
    local name="$1"
    SECURITY_AUTH_INTERACTION_ALLOWED=NO \
        security find-generic-password -s "$STACKPILOT_KEYCHAIN_SERVICE" -a "$name" >/dev/null 2>&1
    local rc=$?
    [ $rc -eq 0 ] && return 0
    return 1
}

_backend_rm() {
    local name="$1"
    security delete-generic-password -s "$STACKPILOT_KEYCHAIN_SERVICE" -a "$name" >/dev/null 2>&1 || true
    return 0
}

# Pure-bash parser of `security dump-keychain` output. Compatible with macOS
# default bash 3.2 and BSD awk (no GNU-specific extensions used).
_backend_list() {
    local svc="" acct="" line
    while IFS= read -r line; do
        case "$line" in
            "keychain: "*)
                # End of previous item — flush if matched our service.
                if [ "$svc" = "$STACKPILOT_KEYCHAIN_SERVICE" ] && [ -n "$acct" ]; then
                    printf '%s\n' "$acct"
                fi
                svc=""; acct=""
                ;;
            *'"svce"<blob>="'*)
                svc="${line#*\"svce\"<blob>=\"}"
                svc="${svc%\"*}"
                ;;
            *'"acct"<blob>="'*)
                acct="${line#*\"acct\"<blob>=\"}"
                acct="${acct%\"*}"
                ;;
        esac
    done < <(security dump-keychain 2>/dev/null)
    # Don't forget the last item in the stream.
    if [ "$svc" = "$STACKPILOT_KEYCHAIN_SERVICE" ] && [ -n "$acct" ]; then
        printf '%s\n' "$acct"
    fi
}
