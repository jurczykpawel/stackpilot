#!/bin/bash

# StackPilot - Mail Domain Setup
# Configures sending domains: SPF audit, DKIM, DMARC, bounce handling.
# Works with any mailer (Listmonk, Mautic, WordPress, custom).
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/setup-mail-domain.sh [DOMAINS...] [--webhook-url=URL] [--dry-run]
#
# Examples:
#   ./local/setup-mail-domain.sh mycompany.com shop.mycompany.com
#   ./local/setup-mail-domain.sh mycompany.com --dry-run
#   ./local/setup-mail-domain.sh --webhook-url=https://mail.example.com/webhooks/service/ses

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_CONFIG="$HOME/.config/cloudflare/config"

# Colors (before i18n so they are available in MSG_ strings)
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
BLUE='\033[0;34m'

# i18n
_MD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_MD_DIR/../lib/i18n.sh"
fi

# State
DOMAINS=()
WEBHOOK_URL=""
DRY_RUN=false
HAS_CLOUDFLARE=false
CF_TOKEN=""
DKIM_ADDED_NAMES=()
DMARC_ADDED=false
DMARC_REPORT_EMAIL=""
SPF_RAW=()

# ─── Argument parsing ──────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --webhook-url=*) WEBHOOK_URL="${arg#*=}" ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            msg "$MSG_MD_HELP_USAGE" "$0"
            echo ""
            msg "$MSG_MD_HELP_DESC"
            msg "$MSG_MD_HELP_MAILERS"
            echo ""
            msg "$MSG_MD_HELP_WHAT"
            msg "$MSG_MD_HELP_0"
            msg "$MSG_MD_HELP_1"
            msg "$MSG_MD_HELP_2"
            msg "$MSG_MD_HELP_3"
            msg "$MSG_MD_HELP_4"
            msg "$MSG_MD_HELP_5"
            echo ""
            msg "$MSG_MD_HELP_OPTS"
            msg "$MSG_MD_HELP_OPT_WEBHOOK"
            msg "$MSG_MD_HELP_OPT_DRYRUN"
            echo ""
            msg "$MSG_MD_HELP_REQ"
            echo ""
            msg "$MSG_MD_HELP_EX_1" "$0"
            msg "$MSG_MD_HELP_EX_2" "$0"
            echo ""
            msg "$MSG_MD_HELP_WRAPPER"
            msg "$MSG_MD_HELP_WRAPPER_LM"
            exit 0
            ;;
        -*) msg "$MSG_MD_UNKNOWN_OPT" "$arg"; exit 1 ;;
        *) DOMAINS+=("$arg") ;;
    esac
done

# ─── Helper functions ──────────────────────────────────────────

ok()   { echo -e "  ${GREEN}✅ $1${NC}"; }
fail() { echo -e "  ${RED}❌ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
info() { echo -e "  ${CYAN}ℹ️  $1${NC}"; }
step() { echo ""; echo -e "${BOLD}── $1 ──────────────────────────────────────────${NC}"; echo ""; }

check_spf() {
    local domain="$1"
    local spf
    spf=$(dig TXT "$domain" +short 2>/dev/null | tr -d '"' | grep -i 'v=spf1' || true)
    if [ -z "$spf" ]; then
        echo "MISSING"
    elif echo "$spf" | grep -q -- '-all'; then
        echo "OK"
    elif echo "$spf" | grep -q '~all'; then
        echo "SOFTFAIL"
    else
        echo "WEAK"
    fi
}

get_spf_raw() {
    local domain="$1"
    dig TXT "$domain" +short 2>/dev/null | tr -d '"' | grep -i 'v=spf1' || true
}

# Map: provider → SPF include
spf_include_for_provider() {
    case "$1" in
        ses)       echo "include:amazonses.com" ;;
        emaillabs) echo "include:emaillabs.net.pl" ;;
        google)    echo "include:_spf.google.com" ;;
        mailgun)   echo "include:mailgun.org" ;;
        resend)    echo "include:resend.com" ;;
        brevo)     echo "include:sendinblue.com" ;;
        postmark)  echo "include:spf.mtasv.net" ;;
        *)         echo "" ;;
    esac
}

check_dmarc() {
    local domain="$1"
    local dmarc
    dmarc=$(dig TXT "_dmarc.$domain" +short 2>/dev/null | tr -d '"' | grep -i 'v=DMARC1' || true)
    if [ -z "$dmarc" ]; then
        echo "MISSING"
    else
        echo "OK"
    fi
}

# Check DKIM via Cloudflare API (looks for *._domainkey.domain records)
check_dkim_cf() {
    local domain="$1"
    local zone_id
    zone_id=$(get_zone_id "$domain")
    [ -z "$zone_id" ] && return 1

    local records
    records=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?per_page=100" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null)

    if command -v jq &>/dev/null; then
        echo "$records" | jq -r '.result[] | select(.name | contains("_domainkey")) | select(.name | endswith("'"$domain"'")) | "    \(.type) \(.name) → \(.content)"' 2>/dev/null
    else
        echo "$records" | tr ',' '\n' | grep -A1 "_domainkey.*$domain" | grep -o '"[^"]*"' | paste - - 2>/dev/null || true
    fi
}

load_cf_config() {
    [ ! -f "$CF_CONFIG" ] && return 1
    CF_TOKEN=$(grep "^API_TOKEN=" "$CF_CONFIG" | cut -d= -f2)
    [ -n "$CF_TOKEN" ]
}

get_zone_id() {
    local domain="$1"
    local root_domain
    root_domain=$(echo "$domain" | rev | cut -d. -f1-2 | rev)
    grep "^${root_domain}=" "$CF_CONFIG" 2>/dev/null | cut -d= -f2
}

cf_add_record() {
    local domain="$1" type="$2" name="$3" content="$4"

    if $DRY_RUN; then
        msg "$MSG_MD_DKIM_DRYRUN_SKIP" "$type" "$name" "$content"
        return 0
    fi

    local zone_id
    zone_id=$(get_zone_id "$domain")

    if [ -z "$zone_id" ]; then
        fail "$(printf "$MSG_MD_CF_WARN")"
        return 1
    fi

    local existing existing_id=""
    existing=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$type&name=$name" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json")

    if command -v jq &>/dev/null; then
        existing_id=$(echo "$existing" | jq -r 'if (.result | length) > 0 then .result[0].id else "" end' 2>/dev/null)
    else
        local count
        count=$(echo "$existing" | grep -o '"count":[0-9]*' | head -1 | sed 's/"count"://')
        if [ "${count:-0}" != "0" ]; then
            existing_id=$(echo "$existing" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
        fi
    fi

    local response
    local json_data="{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\",\"ttl\":3600,\"proxied\":false}"

    if [ -n "$existing_id" ] && [ "$existing_id" != "null" ] && [ "$existing_id" != "" ]; then
        response=$(curl -s -X PUT \
            "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$existing_id" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$json_data")
    else
        response=$(curl -s -X POST \
            "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$json_data")
    fi

    echo "$response" | grep -q '"success":true'
}

open_url() {
    local url="$1"
    $DRY_RUN && return 0
    if command -v open &>/dev/null; then
        open "$url" 2>/dev/null || true
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url" 2>/dev/null || true
    fi
}

# Add DKIM records for one provider
add_dkim_for_provider() {
    local domain="$1"
    local provider="$2"  # ses | emaillabs | custom
    local added=0

    case "$provider" in
    ses)
        msg "$MSG_MD_DKIM_SES_INFO1"
        msg "$MSG_MD_DKIM_SES_INFO2" "$domain"
        msg "$MSG_MD_DKIM_SES_INFO3"
        echo ""
        open_url "https://console.aws.amazon.com/ses/home#/verified-identities"
        msg "$MSG_MD_DKIM_SES_PASTE"
        msg "$MSG_MD_DKIM_SES_EXAMPLE" "$domain"
        echo ""

        for n in 1 2 3; do
            read -p "$(msg_n "$MSG_MD_DKIM_SES_REC" "$n")" rec_line
            [ -z "$rec_line" ] && continue

            rec_line=$(echo "$rec_line" | sed 's/^[[:space:]]*CNAME[[:space:]]*//' | sed 's/[[:space:]]\{1,\}/ /g' | sed 's/\.$//')
            rec_name=$(echo "$rec_line" | awk '{print $1}')
            rec_value=$(echo "$rec_line" | awk '{print $2}')

            # Auto-derive value from name (SES pattern)
            if [ -z "$rec_value" ] && echo "$rec_name" | grep -q '_domainkey'; then
                token=$(echo "$rec_name" | sed "s/\._domainkey\..*//")
                rec_value="${token}.dkim.amazonses.com"
                msg "$MSG_MD_DKIM_SES_AUTO_VAL" "$rec_value"
            fi

            rec_name="${rec_name%.}"
            rec_value="${rec_value%.}"

            if [ -z "$rec_name" ] || [ -z "$rec_value" ]; then
                msg "$MSG_MD_DKIM_SKIP_INVALID"
                continue
            fi

            if $HAS_CLOUDFLARE; then
                if cf_add_record "$domain" "CNAME" "$rec_name" "$rec_value"; then
                    msg "$MSG_MD_DKIM_CF_ADDED" "CNAME" "$rec_name"
                    DKIM_ADDED_NAMES+=("$rec_name")
                    added=$((added + 1))
                else
                    msg "$MSG_MD_DKIM_CF_FAIL" "$rec_name"
                    msg "$MSG_MD_DKIM_CF_MANUAL" "CNAME" "$rec_name" "$rec_value"
                fi
            else
                msg "$MSG_MD_DKIM_DNS_MANUAL" "CNAME" "$rec_name" "$rec_value"
                added=$((added + 1))
            fi
        done
        ;;

    emaillabs)
        msg "$MSG_MD_DKIM_EL_INFO1"
        msg "$MSG_MD_DKIM_EL_INFO2" "$domain"
        echo ""

        msg "$MSG_MD_DKIM_EL_TYPE"
        msg "$MSG_MD_DKIM_EL_TYPE_1"
        msg "$MSG_MD_DKIM_EL_TYPE_2"
        read -p "$(msg_n "$MSG_MD_DKIM_EL_TYPE_CHOOSE")" dtype_choice

        dtype="CNAME"
        [ "$dtype_choice" = "2" ] && dtype="TXT"

        echo ""
        read -p "$(msg_n "$MSG_MD_DKIM_EL_NAME" "$domain")" el_name
        read -p "$(msg_n "$MSG_MD_DKIM_EL_VALUE")" el_value
        echo ""

        el_name="${el_name%.}"
        el_value="${el_value%.}"

        if [ -n "$el_name" ] && [ -n "$el_value" ]; then
            if $HAS_CLOUDFLARE; then
                if cf_add_record "$domain" "$dtype" "$el_name" "$el_value"; then
                    msg "$MSG_MD_DKIM_CF_ADDED" "$dtype" "$el_name"
                    DKIM_ADDED_NAMES+=("$el_name")
                    added=$((added + 1))
                else
                    msg "$MSG_MD_DKIM_EL_CF_FAIL"
                    msg "$MSG_MD_DKIM_EL_MANUAL" "$dtype" "$el_name" "$el_value"
                fi
            else
                msg "$MSG_MD_DKIM_EL_DNS" "$dtype" "$el_name" "$el_value"
                added=$((added + 1))
            fi
        fi
        ;;

    custom)
        msg "$MSG_MD_DKIM_CUSTOM_INFO"
        echo ""
        msg "$MSG_MD_DKIM_CUSTOM_TYPE"
        msg "$MSG_MD_DKIM_CUSTOM_TYPE_1"
        msg "$MSG_MD_DKIM_CUSTOM_TYPE_2"
        read -p "$(msg_n "$MSG_MD_DKIM_CUSTOM_TYPE_CHOOSE")" ctype_choice

        ctype="CNAME"
        [ "$ctype_choice" = "2" ] && ctype="TXT"

        echo ""
        read -p "$(msg_n "$MSG_MD_DKIM_CUSTOM_NAME" "$domain")" c_name
        read -p "$(msg_n "$MSG_MD_DKIM_CUSTOM_VALUE")" c_value
        echo ""

        c_name="${c_name%.}"
        c_value="${c_value%.}"

        if [ -n "$c_name" ] && [ -n "$c_value" ]; then
            if $HAS_CLOUDFLARE; then
                if cf_add_record "$domain" "$ctype" "$c_name" "$c_value"; then
                    msg "$MSG_MD_DKIM_CF_ADDED" "$ctype" "$c_name"
                    DKIM_ADDED_NAMES+=("$c_name")
                    added=$((added + 1))
                else
                    msg "$MSG_MD_DKIM_CUSTOM_CF_FAIL"
                    msg "$MSG_MD_DKIM_CUSTOM_MANUAL" "$ctype" "$c_name" "$c_value"
                fi
            else
                msg "$MSG_MD_DKIM_CUSTOM_DNS" "$ctype" "$c_name" "$c_value"
                added=$((added + 1))
            fi
        fi
        ;;
    esac

    return $added
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

echo ""
msg "$MSG_MD_HEADER_LINE1"
msg "$MSG_MD_HEADER_LINE2"
msg "$MSG_MD_HEADER_LINE3"
echo ""
if $DRY_RUN; then
    msg "$MSG_MD_DRY_RUN_NOTICE"
    echo ""
fi
msg "$MSG_MD_INTRO"
echo ""
msg "$MSG_MD_INTRO_SPF"
msg "$MSG_MD_INTRO_DKIM"
msg "$MSG_MD_INTRO_DMARC"
echo ""

if load_cf_config; then
    HAS_CLOUDFLARE=true
    msg "$MSG_MD_CF_OK"
else
    msg "$MSG_MD_CF_WARN"
    msg "$MSG_MD_CF_INFO"
fi
echo ""

# Domains
if [ ${#DOMAINS[@]} -eq 0 ]; then
    if $DRY_RUN; then
        msg "$MSG_MD_NO_DOMAINS_DRYRUN"
        msg "$MSG_MD_NO_DOMAINS_USAGE" "$0"
        exit 1
    fi
    msg "$MSG_MD_PROMPT_DOMAINS"
    msg "$MSG_MD_PROMPT_DOMAINS_EX"
    echo ""
    read -p "$(msg_n "$MSG_MD_PROMPT_DOMAINS_READ")" -a DOMAINS
    echo ""
fi

if [ ${#DOMAINS[@]} -eq 0 ]; then
    msg "$MSG_MD_NO_DOMAINS_ERR"
    exit 1
fi

# ─── DNS Audit ────────────────────────────────────────────────

step "$(msg_n "$MSG_MD_AUDIT_HEADER")"

msg "$MSG_MD_AUDIT_CHECKING" "${#DOMAINS[@]}"
echo ""

SPF_RESULTS=()
DMARC_RESULTS=()
DKIM_EXISTING=()

for i in "${!DOMAINS[@]}"; do
    domain="${DOMAINS[$i]}"
    SPF_RESULTS[$i]=$(check_spf "$domain")
    SPF_RAW[$i]=$(get_spf_raw "$domain")
    DMARC_RESULTS[$i]=$(check_dmarc "$domain")

    dkim_found=""
    if $HAS_CLOUDFLARE; then
        dkim_found=$(check_dkim_cf "$domain" 2>/dev/null || true)
    fi
    if [ -n "$dkim_found" ]; then
        DKIM_EXISTING[$i]="yes"
    else
        DKIM_EXISTING[$i]="no"
    fi
done

for i in "${!DOMAINS[@]}"; do
    domain="${DOMAINS[$i]}"
    echo -e "  ${BOLD}$domain${NC}"

    case "${SPF_RESULTS[$i]}" in
        OK)       msg "$MSG_MD_SPF_OK" ;;
        SOFTFAIL) msg "$MSG_MD_SPF_SOFTFAIL" ;;
        MISSING)  msg "$MSG_MD_SPF_MISSING" ;;
        *)        msg "$MSG_MD_SPF_WEAK" ;;
    esac
    [ -n "${SPF_RAW[$i]}" ] && echo "    ${SPF_RAW[$i]}"

    if [ "${DKIM_EXISTING[$i]}" = "yes" ]; then
        msg "$MSG_MD_DKIM_CF_OK"
        check_dkim_cf "$domain" 2>/dev/null || true
    else
        if $HAS_CLOUDFLARE; then
            msg "$MSG_MD_DKIM_CF_MISSING"
        else
            msg "$MSG_MD_DKIM_MANUAL"
        fi
    fi

    case "${DMARC_RESULTS[$i]}" in
        OK) msg "$MSG_MD_DMARC_OK" ;;
        *)  msg "$MSG_MD_DMARC_MISSING" ;;
    esac

    echo ""
done

# ─── SPF ──────────────────────────────────────────────────────

step "$(msg_n "$MSG_MD_SPF_STEP")"

msg "$MSG_MD_SPF_EXPLAIN"
msg "$MSG_MD_SPF_EXPLAIN2"
echo ""

for i in "${!DOMAINS[@]}"; do
    domain="${DOMAINS[$i]}"
    spf_status="${SPF_RESULTS[$i]}"
    spf_current="${SPF_RAW[$i]}"

    echo -e "  ${BOLD}$domain${NC}"

    if [ "$spf_status" = "OK" ]; then
        ok "$(printf "$MSG_MD_SPF_OK"): $spf_current"
        echo ""
        continue
    fi

    echo ""
    msg "$MSG_MD_SPF_PROMPT_SMTP" "$domain"
    msg "$MSG_MD_SPF_OPT_1"
    msg "$MSG_MD_SPF_OPT_2"
    msg "$MSG_MD_SPF_OPT_3"
    msg "$MSG_MD_SPF_OPT_4"
    msg "$MSG_MD_SPF_OPT_5"
    msg "$MSG_MD_SPF_OPT_6"
    msg "$MSG_MD_SPF_OPT_7"
    msg "$MSG_MD_SPF_OPT_8"
    msg "$MSG_MD_SPF_OPT_9"
    echo ""

    if $DRY_RUN; then
        if [ "$spf_status" = "MISSING" ]; then
            msg "$MSG_MD_SPF_DRYRUN_MISSING"
        elif [ "$spf_status" = "SOFTFAIL" ]; then
            msg "$MSG_MD_SPF_DRYRUN_SOFTFAIL"
        fi
        msg "$MSG_MD_SPF_DRYRUN_HINT"
        echo ""
        continue
    fi

    NEW_INCLUDES=()
    while true; do
        read -p "$(msg_n "$MSG_MD_SPF_CHOOSE")" -a choices
        echo ""
        for choice in "${choices[@]}"; do
            case "$choice" in
                1) NEW_INCLUDES+=("include:amazonses.com") ;;
                2) NEW_INCLUDES+=("include:emaillabs.net.pl") ;;
                3) NEW_INCLUDES+=("include:_spf.google.com") ;;
                4) NEW_INCLUDES+=("include:mailgun.org") ;;
                5) NEW_INCLUDES+=("include:resend.com") ;;
                6) NEW_INCLUDES+=("include:sendinblue.com") ;;
                7) NEW_INCLUDES+=("include:spf.mtasv.net") ;;
                8)
                    read -p "$(msg_n "$MSG_MD_SPF_CUSTOM_INC")" custom_inc
                    [ -n "$custom_inc" ] && NEW_INCLUDES+=("$custom_inc")
                    ;;
                9) ;;
            esac
        done
        break
    done

    if [ ${#NEW_INCLUDES[@]} -eq 0 ]; then
        echo ""
        continue
    fi

    # Filter out already-present includes
    FILTERED_INCLUDES=()
    for inc in "${NEW_INCLUDES[@]}"; do
        if [ -n "$spf_current" ] && echo "$spf_current" | grep -q "$inc"; then
            msg "$MSG_MD_SPF_ALREADY" "$inc"
        else
            FILTERED_INCLUDES+=("$inc")
        fi
    done

    if [ ${#FILTERED_INCLUDES[@]} -eq 0 ]; then
        msg "$MSG_MD_SPF_ALL_OK"
        echo ""
        continue
    fi

    # Build new record
    if [ -z "$spf_current" ]; then
        new_spf="v=spf1 ${FILTERED_INCLUDES[*]} -all"
    else
        base=$(echo "$spf_current" | sed 's/[~\?\+\-]all$//')
        new_spf="${base}${FILTERED_INCLUDES[*]} -all"
    fi

    # Normalize spaces
    new_spf=$(echo "$new_spf" | tr -s ' ')

    echo ""
    msg "$MSG_MD_SPF_PROPOSAL"
    echo ""
    if [ -n "$spf_current" ]; then
        msg "$MSG_MD_SPF_OLD" "$spf_current"
    else
        msg "$MSG_MD_SPF_OLD_NONE"
    fi
    msg "$MSG_MD_SPF_NEW" "$new_spf"
    echo ""

    # Warn about DNS lookup count (limit 10)
    lookup_count=$(echo "$new_spf" | grep -o 'include:' | wc -l | tr -d ' ')
    if [ "$lookup_count" -gt 8 ]; then
        msg "$MSG_MD_SPF_WARN_LOOKUPS" "$lookup_count"
    fi

    msg "$MSG_MD_SPF_CRITICAL"
    echo ""
    read -p "$(msg_n "$MSG_MD_SPF_CONFIRM")" -n 1 -r
    echo ""

    # Accept y/Y/t/T
    if [[ ! $REPLY =~ ^[TtYy]$ ]]; then
        msg "$MSG_MD_SPF_SKIP"
        msg "$MSG_MD_SPF_SKIP_HINT" "$domain" "$new_spf"
        echo ""
        continue
    fi

    # Second confirmation
    echo ""
    msg "$MSG_MD_SPF_CONFIRM2" "$domain"
    echo "  $new_spf"
    echo ""
    read -p "$(msg_n "$MSG_MD_SPF_CONFIRM2_PROMPT")" confirm
    echo ""

    confirm_word=$(msg_n "$MSG_MD_SPF_CONFIRM2_YES")
    if [ "$confirm" != "$confirm_word" ]; then
        msg "$MSG_MD_SPF_CANCEL"
        msg "$MSG_MD_SPF_SKIP_HINT" "$domain" "$new_spf"
        echo ""
        continue
    fi

    if $HAS_CLOUDFLARE; then
        if cf_add_record "$domain" "TXT" "$domain" "$new_spf"; then
            msg "$MSG_MD_SPF_CF_OK" "$domain"
        else
            msg "$MSG_MD_SPF_CF_FAIL"
            msg "$MSG_MD_SPF_CF_HINT" "$domain" "$new_spf"
        fi
    else
        msg "$MSG_MD_SPF_MANUAL"
        msg "$MSG_MD_SPF_MANUAL_HINT" "$domain" "$new_spf"
    fi
    echo ""
done

# ─── DKIM ─────────────────────────────────────────────────────

step "$(msg_n "$MSG_MD_DKIM_STEP")"

msg "$MSG_MD_DKIM_EXPLAIN"
msg "$MSG_MD_DKIM_EXPLAIN2"
msg "$MSG_MD_DKIM_EXPLAIN3"
echo ""

for i in "${!DOMAINS[@]}"; do
    domain="${DOMAINS[$i]}"
    echo -e "  ${BOLD}📧 $domain${NC}"

    if [ "${DKIM_EXISTING[$i]}" = "yes" ]; then
        msg "$MSG_MD_DKIM_CF_ALREADY"
        if $DRY_RUN; then
            echo ""
            continue
        fi
        read -p "$(msg_n "$MSG_MD_DKIM_ADD_MORE")" -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[TtYy]$ ]]; then
            echo ""
            continue
        fi
    fi

    if $DRY_RUN; then
        if [ "${DKIM_EXISTING[$i]}" != "yes" ]; then
            msg "$MSG_MD_DKIM_DRYRUN_MISSING"
            msg "$MSG_MD_DKIM_DRYRUN_HINT"
        fi
        echo ""
        continue
    fi

    while true; do
        echo ""
        msg "$MSG_MD_DKIM_PROMPT_SMTP" "$domain"
        msg "$MSG_MD_DKIM_OPT_1"
        msg "$MSG_MD_DKIM_OPT_2"
        msg "$MSG_MD_DKIM_OPT_3"
        msg "$MSG_MD_DKIM_OPT_4"
        echo ""
        read -p "$(msg_n "$MSG_MD_DKIM_CHOOSE")" provider_choice
        echo ""

        case "$provider_choice" in
            1) add_dkim_for_provider "$domain" "ses" || true ;;
            2) add_dkim_for_provider "$domain" "emaillabs" || true ;;
            3) add_dkim_for_provider "$domain" "custom" || true ;;
            *) break ;;
        esac

        echo ""
        read -p "$(msg_n "$MSG_MD_DKIM_ADD_ANOTHER" "$domain")" -n 1 -r
        echo ""
        [[ ! $REPLY =~ ^[TtYy]$ ]] && break
    done

    echo ""
done

# ─── DMARC ────────────────────────────────────────────────────

step "$(msg_n "$MSG_MD_DMARC_STEP")"

msg "$MSG_MD_DMARC_EXPLAIN"
msg "$MSG_MD_DMARC_EXPLAIN2"
msg "$MSG_MD_DMARC_EXPLAIN3"
echo ""

# Consolidated report email
if [ ${#DOMAINS[@]} -gt 1 ] && ! $DRY_RUN; then
    msg "$MSG_MD_DMARC_CONSOLIDATED_PROMPT" "${#DOMAINS[@]}"
    msg "$MSG_MD_DMARC_CONSOLIDATED_EX"
    echo ""
    read -p "$(msg_n "$MSG_MD_DMARC_CONSOLIDATED_READ")" DMARC_REPORT_EMAIL
    echo ""
fi

for i in "${!DOMAINS[@]}"; do
    domain="${DOMAINS[$i]}"

    if [ "${DMARC_RESULTS[$i]}" = "OK" ]; then
        msg "$MSG_MD_DMARC_ALREADY" "$domain"
        continue
    fi

    if [ -n "$DMARC_REPORT_EMAIL" ]; then
        rua_email="$DMARC_REPORT_EMAIL"
    else
        rua_email="dmarc-reports@$domain"
    fi

    dmarc_name="_dmarc.$domain"
    dmarc_value="v=DMARC1; p=none; rua=mailto:$rua_email"

    echo -e "  ${BOLD}$domain${NC}"
    msg "$MSG_MD_DMARC_RECORD" "$dmarc_name" "$dmarc_value"
    echo ""

    if $HAS_CLOUDFLARE; then
        if ! $DRY_RUN; then
            read -p "$(msg_n "$MSG_MD_DMARC_CF_CONFIRM")" -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                echo ""
                continue
            fi
        fi
        if cf_add_record "$domain" "TXT" "$dmarc_name" "$dmarc_value"; then
            if $DRY_RUN; then
                msg "$MSG_MD_DMARC_CF_WILL_ADD" "$domain"
            else
                msg "$MSG_MD_DMARC_CF_OK" "$domain"
            fi
            DMARC_ADDED=true
        else
            msg "$MSG_MD_DMARC_CF_FAIL"
            msg "$MSG_MD_DMARC_CF_HINT" "$dmarc_name" "$dmarc_value"
        fi
    else
        msg "$MSG_MD_DMARC_MANUAL"
        msg "$MSG_MD_DMARC_MANUAL_NAME" "$dmarc_name"
        msg "$MSG_MD_DMARC_MANUAL_VALUE" "$dmarc_value"
    fi
    echo ""
done

# Cross-domain DMARC auth records
if [ -n "$DMARC_REPORT_EMAIL" ]; then
    report_domain="${DMARC_REPORT_EMAIL#*@}"

    msg "$MSG_MD_DMARC_CROSS_HEADER"
    echo ""
    msg "$MSG_MD_DMARC_CROSS_EXPLAIN" "$DMARC_REPORT_EMAIL"
    msg "$MSG_MD_DMARC_CROSS_EXPLAIN2" "$report_domain"
    echo ""

    for domain in "${DOMAINS[@]}"; do
        [ "$domain" = "$report_domain" ] && continue

        auth_name="${report_domain}._report._dmarc.${domain}"
        auth_value="v=DMARC1"

        echo "  $auth_name  TXT  \"$auth_value\""

        if $HAS_CLOUDFLARE; then
            if cf_add_record "$domain" "TXT" "$auth_name" "$auth_value"; then
                msg "$MSG_MD_DMARC_CROSS_CF_OK" "$domain" "$report_domain"
            else
                msg "$MSG_MD_DMARC_CROSS_CF_FAIL"
                msg "$MSG_MD_DMARC_CROSS_MANUAL" "$domain"
                msg "$MSG_MD_DMARC_CROSS_MANUAL_HINT" "$auth_name" "$auth_value"
            fi
        else
            msg "$MSG_MD_DMARC_CROSS_MANUAL" "$domain"
            msg "$MSG_MD_DMARC_CROSS_MANUAL_HINT" "$auth_name" "$auth_value"
        fi
    done
    echo ""
fi

# ─── DNS Verification ─────────────────────────────────────────

if $HAS_CLOUDFLARE && { [ ${#DKIM_ADDED_NAMES[@]} -gt 0 ] || $DMARC_ADDED; }; then
    step "$(msg_n "$MSG_MD_VERIFY_STEP")"

    msg "$MSG_MD_VERIFY_CHECKING"
    echo ""
    $DRY_RUN || sleep 2

    for name in "${DKIM_ADDED_NAMES[@]}"; do
        result=$(dig CNAME "$name" +short 2>/dev/null || true)
        [ -z "$result" ] && result=$(dig TXT "$name" +short 2>/dev/null | tr -d '"' || true)
        if [ -n "$result" ]; then
            msg "$MSG_MD_VERIFY_DKIM_OK" "$name" "$(echo "$result" | head -1)"
        else
            msg "$MSG_MD_VERIFY_DKIM_WAIT" "$name"
        fi
    done

    for domain in "${DOMAINS[@]}"; do
        dmarc=$(dig TXT "_dmarc.$domain" +short 2>/dev/null | tr -d '"' || true)
        if echo "$dmarc" | grep -qi 'DMARC1'; then
            msg "$MSG_MD_DMARC_OK"
        fi
    done
    echo ""
fi

# ─── Bounce handling (SES) ────────────────────────────────────

step "$(msg_n "$MSG_MD_BOUNCE_STEP")"

msg "$MSG_MD_BOUNCE_EXPLAIN"
msg "$MSG_MD_BOUNCE_EXPLAIN2"
echo ""

if [ -n "$WEBHOOK_URL" ]; then
    msg "$MSG_MD_BOUNCE_SNS_HEADER"
    echo ""
    msg "$MSG_MD_BOUNCE_SNS_EXPLAIN"
    echo ""
    msg "$MSG_MD_BOUNCE_SNS_STEP1"
    for domain in "${DOMAINS[@]}"; do
        prefix=$(echo "$domain" | cut -d. -f1 | head -c10)
        msg "$MSG_MD_BOUNCE_SNS_BOUNCE" "$prefix"
        msg "$MSG_MD_BOUNCE_SNS_COMPLAINT" "$prefix"
    done
    echo ""
    msg "$MSG_MD_BOUNCE_SNS_STEP2"
    msg "$MSG_MD_BOUNCE_SNS_PROTO"
    msg "$MSG_MD_BOUNCE_SNS_ENDPOINT" "$WEBHOOK_URL"
    msg "$MSG_MD_BOUNCE_SNS_AUTO"
    echo ""
    msg "$MSG_MD_BOUNCE_SNS_STEP3"
    msg "$MSG_MD_BOUNCE_SNS_NOTIF"
    msg "$MSG_MD_BOUNCE_SNS_BOUNCE_ASSIGN"
    msg "$MSG_MD_BOUNCE_SNS_COMP_ASSIGN"
    echo ""

    open_url "https://console.aws.amazon.com/sns/v3/home#/topics"

    if ! $DRY_RUN; then
        read -p "$(msg_n "$MSG_MD_BOUNCE_SNS_PRESS_ENTER")" _skip
        echo ""
    fi
else
    msg "$MSG_MD_BOUNCE_NO_URL"
    msg "$MSG_MD_BOUNCE_NO_URL_SNS"
    msg "$MSG_MD_BOUNCE_NO_URL_SUB"
    msg "$MSG_MD_BOUNCE_NO_URL_SES"
    echo ""
    msg "$MSG_MD_BOUNCE_NO_URL_TIP"
    echo ""
fi

# ─── Summary ──────────────────────────────────────────────────

step "$(msg_n "$MSG_MD_SUMMARY_STEP")"

msg "$MSG_MD_SUMMARY_BOX1"
msg "$MSG_MD_SUMMARY_BOX2"
msg "$MSG_MD_SUMMARY_BOX3"
if [ ${#DKIM_ADDED_NAMES[@]} -gt 0 ]; then
msg "$MSG_MD_SUMMARY_DKIM_ADDED"
elif [ -n "$(printf '%s' "${DKIM_EXISTING[@]}" | grep yes)" ]; then
msg "$MSG_MD_SUMMARY_DKIM_EXISTED"
else
msg "$MSG_MD_SUMMARY_DKIM_CHECK"
fi
DMARC_ALL_OK=true
for i in "${!DOMAINS[@]}"; do
    [ "${DMARC_RESULTS[$i]}" != "OK" ] && ! $DMARC_ADDED && DMARC_ALL_OK=false
done
if $DMARC_ADDED; then
msg "$MSG_MD_SUMMARY_DMARC_ADDED"
elif $DMARC_ALL_OK; then
msg "$MSG_MD_SUMMARY_DMARC_EXISTED"
else
msg "$MSG_MD_SUMMARY_DMARC_CHECK"
fi
if [ -n "$DMARC_REPORT_EMAIL" ]; then
msg "$MSG_MD_SUMMARY_DMARC_AUTH"
fi
msg "$MSG_MD_SUMMARY_BOX4"
echo ""
msg "$MSG_MD_NEXT_STEPS"
echo ""
msg "$MSG_MD_NEXT_1"
msg "$MSG_MD_NEXT_1B"
msg "$MSG_MD_NEXT_1C"
echo ""
msg "$MSG_MD_NEXT_2"
for domain in "${DOMAINS[@]}"; do
    rua_email="${DMARC_REPORT_EMAIL:-dmarc-reports@$domain}"
    msg "$MSG_MD_NEXT_2B" "$domain" "$rua_email"
done
echo ""
if [ -n "$DMARC_REPORT_EMAIL" ]; then
msg "$MSG_MD_NEXT_3" "$DMARC_REPORT_EMAIL"
echo ""
fi
msg "$MSG_MD_NEXT_4"
echo ""
