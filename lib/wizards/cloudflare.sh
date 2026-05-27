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
    echo "wizard_run not yet implemented (Task 10 follow-up)" >&2
    return 1
}
