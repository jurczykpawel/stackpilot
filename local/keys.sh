#!/bin/bash
# stackpilot keystore CLI.
# Usage: ./local/keys.sh <subcommand> [args]

set -u

_KEYS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_KEYS_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$_REPO_ROOT/lib/keystore/core.sh"

usage() {
    cat <<EOF
stackpilot keys — manage stackpilot secrets in the OS keystore

Usage:
  ./local/keys.sh <subcommand> [args]

Subcommands:
  add <provider>              Run the interactive wizard for <provider>
  get <name>                  Print stored value to stdout
  list                        List stored key names (no values)
  rm <name|provider>          Remove a single key or all keys for a provider
  test <provider>             Verify all provider keys exist + still valid
  backend                     Print active keystore backend
  migrate <provider>          Import legacy plain-text config to keystore
  help, --help                Show this message

Backends:
  Auto-detected: macOS Keychain → Linux libsecret → plain file (fallback).
  Override:      STACKPILOT_KEYSTORE=keychain|libsecret|file

Inspect raw on macOS:
  security find-generic-password -s stackpilot -a <name> -w
EOF
}

cmd_add() {
    local provider="${1:-}"
    if [ -z "$provider" ]; then
        echo "keys add: missing provider name" >&2
        return 2
    fi
    local wizard="$_REPO_ROOT/lib/wizards/$provider.sh"
    if [ ! -f "$wizard" ]; then
        echo "keys add: no wizard for provider '$provider' (looked for $wizard)" >&2
        return 2
    fi
    # shellcheck source=/dev/null
    source "$_REPO_ROOT/lib/wizards/_helpers.sh"
    # shellcheck source=/dev/null
    source "$_REPO_ROOT/lib/wizards/_contract.sh"
    # shellcheck source=/dev/null
    source "$wizard"
    wizard_assert_contract_or_die "$provider" || return 2
    wizard_run
}

cmd_get() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "keys get: missing name" >&2
        return 2
    fi
    local val
    val=$(keystore_get "$name") || {
        echo "keys get: '$name' not found; run: ./local/keys.sh add <provider>" >&2
        return 1
    }
    printf '%s' "$val"
}

cmd_list() {
    local names
    names=$(keystore_list)
    if [ -z "$names" ]; then
        echo "no keys stored (backend: $(keystore_backend))"
        return 0
    fi
    echo "Backend: $(keystore_backend)"
    echo "Keys:"
    printf '%s\n' "$names" | sed 's/^/  /'
}

cmd_rm() {
    local target="${1:-}"
    if [ -z "$target" ]; then
        echo "keys rm: missing name or provider" >&2
        return 2
    fi
    local wizard="$_REPO_ROOT/lib/wizards/$target.sh"
    if [ -f "$wizard" ]; then
        # shellcheck source=/dev/null
        source "$_REPO_ROOT/lib/wizards/_helpers.sh"
        # shellcheck source=/dev/null
        source "$wizard"
        local n
        for n in $(wizard_required_keys); do
            keystore_rm "$n"
            echo "  removed $n"
        done
        return 0
    fi
    keystore_rm "$target"
    echo "  removed $target"
}

cmd_test() {
    local provider="${1:-}"
    if [ -z "$provider" ]; then
        echo "keys test: missing provider name" >&2
        return 2
    fi
    local wizard="$_REPO_ROOT/lib/wizards/$provider.sh"
    if [ ! -f "$wizard" ]; then
        echo "keys test: no wizard for '$provider'" >&2
        return 2
    fi
    # shellcheck source=/dev/null
    source "$_REPO_ROOT/lib/wizards/_helpers.sh"
    # shellcheck source=/dev/null
    source "$wizard"
    wizard_check
    local rc=$?
    case $rc in
        0) echo "OK $provider: all keys present and valid" ;;
        1) echo "MISSING $provider: some keys missing — run './local/keys.sh add $provider'" ;;
        2) echo "INVALID $provider: keys present but failed validation" ;;
        *) echo "ERR $provider: error (rc=$rc)" ;;
    esac
    return $rc
}

cmd_backend() {
    keystore_backend
    echo
}

cmd_migrate() {
    local provider="${1:-}"
    if [ "$provider" != "cloudflare" ]; then
        echo "keys migrate: only 'cloudflare' supported in v1" >&2
        return 2
    fi
    local src="$HOME/.config/cloudflare/config"
    if [ ! -f "$src" ]; then
        echo "keys migrate: source not found at $src" >&2
        return 1
    fi
    local CF_API_TOKEN="" CF_ACCOUNT_ID=""
    # shellcheck source=/dev/null
    source "$src" 2>/dev/null || true
    if [ -z "$CF_API_TOKEN" ]; then
        echo "keys migrate: CF_API_TOKEN not found in $src" >&2
        return 2
    fi
    keystore_set cloudflare_api_token "$CF_API_TOKEN" || return 5
    echo "  imported cloudflare_api_token"
    if [ -n "$CF_ACCOUNT_ID" ]; then
        keystore_set cloudflare_account_id "$CF_ACCOUNT_ID" || return 5
        echo "  imported cloudflare_account_id"
    fi
    echo
    echo "  Verify: ./local/keys.sh list"
    echo "  To delete legacy file once verified: rm $src"
}

main() {
    local sub="${1:-help}"
    shift || true
    case "$sub" in
        add) cmd_add "$@" ;;
        get) cmd_get "$@" ;;
        list) cmd_list "$@" ;;
        rm) cmd_rm "$@" ;;
        test) cmd_test "$@" ;;
        backend) cmd_backend "$@" ;;
        migrate) cmd_migrate "$@" ;;
        help|--help|-h) usage; return 0 ;;
        *) echo "keys: unknown subcommand '$sub'" >&2; usage >&2; return 2 ;;
    esac
}

main "$@"
