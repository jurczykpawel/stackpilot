# Canonical key names allowlist. Single source of truth for what keys
# stackpilot will store. Adding a new key requires editing this file.

KEYSTORE_CANONICAL_NAMES=(
    cloudflare_api_token
    cloudflare_account_id
)

_keystore_is_canonical() {
    local name="$1"
    local n
    for n in "${KEYSTORE_CANONICAL_NAMES[@]}"; do
        if [ "$n" = "$name" ]; then
            return 0
        fi
    done
    return 1
}
