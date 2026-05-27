# Cloudflare wizard — first provider implementation.
# Configurable for tests via STACKPILOT_CF_API_URL.

: "${STACKPILOT_CF_API_URL:=https://api.cloudflare.com}"

_CF_PROVIDER="cloudflare"

wizard_required_keys() {
    echo cloudflare_api_token
    echo cloudflare_account_id
}

# _cf_curl URL
# Echoes "<http_code>|<body>" on stdout. Exit 3 on network failure.
# Uses _CF_TOKEN_FOR_VALIDATION env var as Bearer token.
_cf_curl() {
    local url="$1"
    local token="${_CF_TOKEN_FOR_VALIDATION:-}"
    local out
    out=$(curl -sS --max-time 10 \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -w '\n__HTTP_CODE__:%{http_code}' \
        "$url" 2>/dev/null) || return 3
    local code
    code=$(printf '%s' "$out" | awk -F: '/^__HTTP_CODE__:/ {print $2}' | tail -1)
    local body
    body=$(printf '%s' "$out" | sed '/^__HTTP_CODE__:/d')
    printf '%s|%s' "$code" "$body"
    return 0
}

wizard_validate() {
    local key="$1" value="$2"
    case "$key" in
        cloudflare_api_token)
            _CF_TOKEN_FOR_VALIDATION="$value"
            local v code body
            v=$(_cf_curl "$STACKPILOT_CF_API_URL/client/v4/user/tokens/verify") || {
                emit_error 3 "$_CF_PROVIDER" "$key" "cannot reach $STACKPILOT_CF_API_URL" "check network and try again"
                return 3
            }
            code="${v%%|*}"
            if [ "$code" != "200" ]; then
                emit_error 2 "$_CF_PROVIDER" "$key" "API returned $code on /user/tokens/verify" "token revoked or wrong value"
                return 2
            fi
            local a
            a=$(_cf_curl "$STACKPILOT_CF_API_URL/client/v4/accounts")
            code="${a%%|*}"
            if [ "$code" != "200" ]; then
                emit_error 2 "$_CF_PROVIDER" "$key" "API returned $code on /accounts" "token has no account-level access"
                return 2
            fi
            body="${a#*|}"
            local acc_id
            acc_id=$(printf '%s' "$body" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    res = d.get('result', []) or []
    if not res:
        sys.exit(2)
    print(res[0]['id'])
except Exception:
    sys.exit(1)
" 2>/dev/null)
            if [ -z "$acc_id" ]; then
                emit_error 4 "$_CF_PROVIDER" "$key" "token has no accessible Cloudflare accounts" "token must have at least one account permission"
                return 4
            fi
            # Scope smoke tests
            local p
            p=$(_cf_curl "$STACKPILOT_CF_API_URL/client/v4/accounts/$acc_id/pages/projects?per_page=1")
            if [ "${p%%|*}" = "403" ]; then
                emit_error 4 "$_CF_PROVIDER" "$key" "missing scope: Account → Cloudflare Pages → Edit" "recreate token with Pages:Edit permission"
                return 4
            fi
            local r
            r=$(_cf_curl "$STACKPILOT_CF_API_URL/client/v4/accounts/$acc_id/r2/buckets?per_page=1")
            if [ "${r%%|*}" = "403" ]; then
                emit_error 4 "$_CF_PROVIDER" "$key" "missing scope: Account → Workers R2 Storage → Edit" "recreate token with R2:Edit permission"
                return 4
            fi
            local z
            z=$(_cf_curl "$STACKPILOT_CF_API_URL/client/v4/zones?per_page=1")
            if [ "${z%%|*}" = "403" ]; then
                emit_error 4 "$_CF_PROVIDER" "$key" "missing scope: Zone → Zone → Read" "recreate token with Zone:Read permission"
                return 4
            fi
            return 0
            ;;
        cloudflare_account_id)
            if [[ ! "$value" =~ ^[a-f0-9]{32}$ ]]; then
                emit_error 2 "$_CF_PROVIDER" "$key" "account ID must be 32 lowercase hex chars" "copy ID from dash.cloudflare.com sidebar"
                return 2
            fi
            return 0
            ;;
        *)
            emit_error 2 "$_CF_PROVIDER" "$key" "unknown key for cloudflare wizard" "use cloudflare_api_token or cloudflare_account_id"
            return 2
            ;;
    esac
}

wizard_check() {
    local key
    for key in $(wizard_required_keys); do
        if ! keystore_has "$key"; then return 1; fi
    done
    local token
    token=$(keystore_get cloudflare_api_token) || return 1
    wizard_validate cloudflare_api_token "$token" >/dev/null 2>&1 || return 2
    return 0
}

wizard_run() {
    if wizard_check >/dev/null 2>&1; then
        echo "Cloudflare already configured and valid. Use './local/keys.sh test cloudflare' to re-verify."
        return 0
    fi

    cat <<EOF

  ┌─────────────────────────────────────────────────────────┐
  │  Setting up Cloudflare                                  │
  │  Required: API Token + Account ID                       │
  │  Storage:  $(keystore_backend) backend                  │
  └─────────────────────────────────────────────────────────┘

EOF

    print_step 1 4 "Opening Cloudflare API Tokens page..."
    open_browser "https://dash.cloudflare.com/profile/api-tokens"
    prompt_continue "        Press Enter when the page is open. "

    print_step 2 4 "Create a Custom Token with these permissions:"
    cat <<EOF

        Account → Cloudflare Pages       → Edit
        Account → Workers R2 Storage     → Edit
        Zone    → DNS                    → Edit
        Zone    → Zone                   → Read

        Account Resources: All accounts (or specific)
        Zone Resources:    All zones from all accounts (or specific)
        TTL: no expiry

EOF
    prompt_continue "        Press Enter when you have the token shown on screen. "

    print_step 3 4 "Paste your token (input hidden)..."
    local token
    token=$(prompt_secret "        Token: ")
    if [ -z "$token" ]; then
        echo "        Empty input — cancelled." >&2
        return 1
    fi

    echo "        Verifying..."
    wizard_validate cloudflare_api_token "$token"
    local rc=$?
    if [ $rc -ne 0 ]; then
        return $rc
    fi
    echo "        ✓ Token valid"

    _CF_TOKEN_FOR_VALIDATION="$token"
    local accounts_resp accounts_body accounts_json n_accounts account_id
    accounts_resp=$(_cf_curl "$STACKPILOT_CF_API_URL/client/v4/accounts")
    accounts_body="${accounts_resp#*|}"
    accounts_json=$(printf '%s' "$accounts_body" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    res = d.get('result', []) or []
    for a in res:
        print(f\"{a['id']}\\t{a.get('name','')}\")
except Exception:
    sys.exit(1)
" 2>/dev/null)
    n_accounts=$(printf '%s\n' "$accounts_json" | grep -c .)
    if [ "$n_accounts" -eq 1 ]; then
        account_id=$(printf '%s' "$accounts_json" | head -1 | cut -f1)
        local account_name
        account_name=$(printf '%s' "$accounts_json" | head -1 | cut -f2)
        echo "        ✓ Found 1 account: $account_name ($account_id)"
    else
        echo "        Multiple accounts available:"
        local i=1
        while IFS=$'\t' read -r id name; do
            echo "          $i) $name ($id)"
            i=$((i+1))
        done <<< "$accounts_json"
        local choice
        if [ -t 0 ]; then
            read -r -p "        Pick account number: " choice
        else
            read -r -p "        Pick account number: " choice < /dev/tty 2>/dev/tty
        fi
        account_id=$(printf '%s\n' "$accounts_json" | sed -n "${choice}p" | cut -f1)
        if [ -z "$account_id" ]; then
            echo "        Invalid choice — cancelled." >&2
            return 1
        fi
    fi

    print_step 4 4 "Saving to keystore..."
    keystore_set cloudflare_api_token "$token" || return 5
    echo "        ✓ cloudflare_api_token → $(keystore_backend)"
    keystore_set cloudflare_account_id "$account_id" || return 5
    echo "        ✓ cloudflare_account_id → $(keystore_backend)"
    echo
    echo "  All set. To inspect later:  ./local/keys.sh list"
    echo "  To remove:                  ./local/keys.sh rm cloudflare"
    return 0
}
