#!/bin/bash

# Mikrus Toolbox - Mail Domain Setup
# Konfiguruje domeny do wysyłki maili: SPF audit, DKIM, DMARC, bounce handling.
# Działa z dowolnym mailerem (Listmonk, Mautic, WordPress, własny).
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   ./local/setup-mail-domain.sh [DOMENY...] [--webhook-url=URL] [--dry-run]
#
# Przykłady:
#   ./local/setup-mail-domain.sh mojafirma.pl sklep.mojafirma.pl
#   ./local/setup-mail-domain.sh mojafirma.pl --dry-run
#   ./local/setup-mail-domain.sh --webhook-url=https://mail.example.com/webhooks/service/ses

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_CONFIG="$HOME/.config/cloudflare/config"

# Kolory
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Stan
DOMAINS=()
WEBHOOK_URL=""
DRY_RUN=false
HAS_CLOUDFLARE=false
CF_TOKEN=""
DKIM_ADDED_NAMES=()
DMARC_ADDED=false
DMARC_REPORT_EMAIL=""
SPF_RAW=()

# ─── Parsowanie argumentów ──────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --webhook-url=*) WEBHOOK_URL="${arg#*=}" ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "Użycie: $0 [DOMENY...] [--webhook-url=URL]"
            echo ""
            echo "Konfiguruje domeny do wysyłki maili (SPF, DKIM, DMARC)."
            echo "Działa z dowolnym mailerem — Listmonk, Mautic, WordPress, własny."
            echo ""
            echo "Co robi:"
            echo "  0. Audyt DNS — sprawdza SPF, DKIM (via Cloudflare API), DMARC"
            echo "  1. SPF — proponuje include'y na podstawie dostawcy SMTP"
            echo "  2. DKIM — prowadzi przez dodanie rekordów z SES/EmailLabs/innego"
            echo "  3. DMARC — dodaje politykę ochrony + cross-domain auth records"
            echo "  4. Bounce handling — instrukcje SNS (jeśli --webhook-url)"
            echo "  5. Weryfikacja DNS — sprawdza propagację"
            echo ""
            echo "Opcje:"
            echo "  --webhook-url=URL   URL webhooka bounce (np. .../webhooks/service/ses)"
            echo "  --dry-run           Tylko audyt DNS — nie modyfikuje nic"
            echo ""
            echo "Wymaga wcześniejszej konfiguracji Cloudflare: ./local/setup-cloudflare.sh"
            echo ""
            echo "Przykłady:"
            echo "  $0 mojafirma.pl sklep.mojafirma.pl"
            echo "  $0 --webhook-url=https://mail.example.com/webhooks/service/ses"
            echo ""
            echo "Wrapper per mailer:"
            echo "  ./local/setup-listmonk-mail.sh  — dodaje konfigurację Listmonk API"
            exit 0
            ;;
        -*) echo -e "${RED}❌ Nieznana opcja: $arg${NC}"; exit 1 ;;
        *) DOMAINS+=("$arg") ;;
    esac
done

# ─── Funkcje pomocnicze ─────────────────────────────────────

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

# Mapa: provider → include do SPF
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

# Sprawdź DKIM przez Cloudflare API (szuka rekordów *._domainkey.domain)
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
        info "[DRY-RUN] Dodałbym: $type $name → $content"
        return 0
    fi

    local zone_id
    zone_id=$(get_zone_id "$domain")

    if [ -z "$zone_id" ]; then
        fail "Brak Zone ID dla $domain — uruchom ./local/setup-cloudflare.sh"
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

# Dodaje rekordy DKIM dla jednego dostawcy
add_dkim_for_provider() {
    local domain="$1"
    local provider="$2"  # ses | emaillabs | custom
    local added=0

    case "$provider" in
    ses)
        echo "  📋 W konsoli AWS SES:"
        echo "     Verified Identities → $domain → Authentication → DKIM"
        echo "     Skopiuj 3 rekordy CNAME (Name + Value)"
        echo ""
        open_url "https://console.aws.amazon.com/ses/home#/verified-identities"
        echo "  Wklej 3 rekordy (format: NAZWA WARTOŚĆ, oddzielone spacją):"
        echo "  Przykład: abc123._domainkey.$domain abc123.dkim.amazonses.com"
        echo ""

        for n in 1 2 3; do
            read -p "  Rekord $n: " rec_line
            [ -z "$rec_line" ] && continue

            rec_line=$(echo "$rec_line" | sed 's/^[[:space:]]*CNAME[[:space:]]*//' | sed 's/[[:space:]]\{1,\}/ /g' | sed 's/\.$//')
            rec_name=$(echo "$rec_line" | awk '{print $1}')
            rec_value=$(echo "$rec_line" | awk '{print $2}')

            # Auto-derive wartość z nazwy (wzorzec SES)
            if [ -z "$rec_value" ] && echo "$rec_name" | grep -q '_domainkey'; then
                token=$(echo "$rec_name" | sed "s/\._domainkey\..*//")
                rec_value="${token}.dkim.amazonses.com"
                echo "     → Wartość (auto): $rec_value"
            fi

            rec_name="${rec_name%.}"
            rec_value="${rec_value%.}"

            if [ -z "$rec_name" ] || [ -z "$rec_value" ]; then
                warn "Pominięto — nieprawidłowy format"
                continue
            fi

            if $HAS_CLOUDFLARE; then
                if cf_add_record "$domain" "CNAME" "$rec_name" "$rec_value"; then
                    ok "CNAME: $rec_name"
                    DKIM_ADDED_NAMES+=("$rec_name")
                    added=$((added + 1))
                else
                    fail "Nie udało się dodać: $rec_name"
                    echo "     Dodaj ręcznie: Typ=CNAME | Nazwa=$rec_name | Wartość=$rec_value | Proxy=OFF"
                fi
            else
                echo "     Dodaj w DNS: Typ=CNAME | Nazwa=$rec_name | Wartość=$rec_value | TTL=3600 | Proxy=OFF"
                added=$((added + 1))
            fi
        done
        ;;

    emaillabs)
        echo "  📋 W panelu EmailLabs:"
        echo "     Ustawienia → Domeny → $domain → DKIM"
        echo ""

        echo "  Typ rekordu DKIM?"
        echo "  1) CNAME (częstsze)"
        echo "  2) TXT"
        read -p "  Typ (1/2): " dtype_choice

        dtype="CNAME"
        [ "$dtype_choice" = "2" ] && dtype="TXT"

        echo ""
        read -p "  Nazwa rekordu (np. emaillabs._domainkey.$domain): " el_name
        read -p "  Wartość: " el_value
        echo ""

        el_name="${el_name%.}"
        el_value="${el_value%.}"

        if [ -n "$el_name" ] && [ -n "$el_value" ]; then
            if $HAS_CLOUDFLARE; then
                if cf_add_record "$domain" "$dtype" "$el_name" "$el_value"; then
                    ok "$dtype: $el_name"
                    DKIM_ADDED_NAMES+=("$el_name")
                    added=$((added + 1))
                else
                    fail "Nie udało się dodać"
                    echo "     Dodaj ręcznie: Typ=$dtype | Nazwa=$el_name | Wartość=$el_value"
                fi
            else
                echo "     Dodaj w DNS: Typ=$dtype | Nazwa=$el_name | Wartość=$el_value | TTL=3600"
                added=$((added + 1))
            fi
        fi
        ;;

    custom)
        echo "  Podaj rekord DKIM od swojego dostawcy SMTP."
        echo ""
        echo "  Typ rekordu?"
        echo "  1) CNAME"
        echo "  2) TXT"
        read -p "  Typ (1/2): " ctype_choice

        ctype="CNAME"
        [ "$ctype_choice" = "2" ] && ctype="TXT"

        echo ""
        read -p "  Nazwa rekordu (np. selector._domainkey.$domain): " c_name
        read -p "  Wartość: " c_value
        echo ""

        c_name="${c_name%.}"
        c_value="${c_value%.}"

        if [ -n "$c_name" ] && [ -n "$c_value" ]; then
            if $HAS_CLOUDFLARE; then
                if cf_add_record "$domain" "$ctype" "$c_name" "$c_value"; then
                    ok "$ctype: $c_name"
                    DKIM_ADDED_NAMES+=("$c_name")
                    added=$((added + 1))
                else
                    fail "Nie udało się dodać"
                    echo "     Dodaj ręcznie: Typ=$ctype | Nazwa=$c_name | Wartość=$c_value"
                fi
            else
                echo "     Dodaj w DNS: Typ=$ctype | Nazwa=$c_name | Wartość=$c_value | TTL=3600"
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
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  📧 Konfiguracja domen wysyłkowych                            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
if $DRY_RUN; then
    echo -e "${YELLOW}${BOLD}  🔍 TRYB DRY-RUN — tylko audyt, nic nie zmieniam${NC}"
    echo ""
fi
echo "Skonfiguruję domeny żeby maile trafiały do Inbox, nie do Spamu."
echo ""
echo "  SPF   — kto może wysyłać maile z Twojej domeny"
echo "  DKIM  — podpis cyfrowy (dowód autentyczności maila)"
echo "  DMARC — polityka: co robić z niepodpisanymi mailami"
echo ""

if load_cf_config; then
    HAS_CLOUDFLARE=true
    ok "Cloudflare API — rekordy DNS dodam automatycznie"
else
    warn "Brak konfiguracji Cloudflare — pokażę rekordy do ręcznego dodania"
    info "Żeby zautomatyzować: ./local/setup-cloudflare.sh"
fi
echo ""

# Domeny
if [ ${#DOMAINS[@]} -eq 0 ]; then
    if $DRY_RUN; then
        fail "Dry-run wymaga podania domen jako argumentów!"
        echo "  Użycie: $0 mojafirma.pl --dry-run"
        exit 1
    fi
    echo "Podaj domeny wysyłkowe (oddziel spacją)."
    echo "Np: mojafirma.pl sklep.example.com"
    echo ""
    read -p "Domeny: " -a DOMAINS
    echo ""
fi

if [ ${#DOMAINS[@]} -eq 0 ]; then
    fail "Nie podano żadnych domen!"
    exit 1
fi

# ─── Audyt DNS ───────────────────────────────────────────────

step "Audyt DNS"

echo "Sprawdzam rekordy dla ${#DOMAINS[@]} domen..."
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
        OK)       ok "SPF: OK (-all)" ;;
        SOFTFAIL) warn "SPF: ~all (softfail) — zalecane -all" ;;
        MISSING)  fail "SPF: brak — maile będą odrzucane!" ;;
        *)        warn "SPF: niestandardowe" ;;
    esac
    [ -n "${SPF_RAW[$i]}" ] && echo "    ${SPF_RAW[$i]}"

    if [ "${DKIM_EXISTING[$i]}" = "yes" ]; then
        ok "DKIM: znalezione rekordy _domainkey w Cloudflare"
        check_dkim_cf "$domain" 2>/dev/null || true
    else
        if $HAS_CLOUDFLARE; then
            fail "DKIM: brak rekordów _domainkey w Cloudflare"
        else
            info "DKIM: wymaga ręcznej weryfikacji"
        fi
    fi

    case "${DMARC_RESULTS[$i]}" in
        OK) ok "DMARC: OK" ;;
        *)  fail "DMARC: brak" ;;
    esac

    echo ""
done

# ─── SPF ─────────────────────────────────────────────────────

step "Krok 1: SPF — kto może wysyłać maile z Twojej domeny"

echo "SPF to rekord TXT na domenie. Mówi serwerom pocztowym:"
echo "\"tylko te serwery mogą wysyłać maile z mojej domeny\"."
echo ""

for i in "${!DOMAINS[@]}"; do
    domain="${DOMAINS[$i]}"
    spf_status="${SPF_RESULTS[$i]}"
    spf_current="${SPF_RAW[$i]}"

    echo -e "  ${BOLD}$domain${NC}"

    if [ "$spf_status" = "OK" ]; then
        ok "SPF wygląda dobrze: $spf_current"
        echo ""
        continue
    fi

    # Zbierz include'y do dodania
    echo ""
    echo "  Jaki SMTP wysyła maile z $domain? (zaznacz wszystkie)"
    echo "  1) Amazon SES"
    echo "  2) EmailLabs"
    echo "  3) Google Workspace"
    echo "  4) Mailgun"
    echo "  5) Resend"
    echo "  6) Brevo (Sendinblue)"
    echo "  7) Postmark"
    echo "  8) Inny (podam ręcznie)"
    echo "  9) Pomiń"
    echo ""

    if $DRY_RUN; then
        if [ "$spf_status" = "MISSING" ]; then
            warn "Brak SPF — trzeba utworzyć rekord"
        elif [ "$spf_status" = "SOFTFAIL" ]; then
            warn "SPF używa ~all — zalecane -all"
        fi
        echo "     Uruchom bez --dry-run żeby skonfigurować"
        echo ""
        continue
    fi

    NEW_INCLUDES=()
    while true; do
        read -p "  Wybierz (1-9, można wiele np. '1 2'): " -a choices
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
                    read -p "  Podaj include (np. include:smtp.example.com): " custom_inc
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

    # Odfiltruj już istniejące include'y
    FILTERED_INCLUDES=()
    for inc in "${NEW_INCLUDES[@]}"; do
        if [ -n "$spf_current" ] && echo "$spf_current" | grep -q "$inc"; then
            info "$inc — już w rekordzie"
        else
            FILTERED_INCLUDES+=("$inc")
        fi
    done

    if [ ${#FILTERED_INCLUDES[@]} -eq 0 ]; then
        ok "Wszystkie include już są w rekordzie SPF"
        echo ""
        continue
    fi

    # Zbuduj nowy rekord
    if [ -z "$spf_current" ]; then
        # Brak SPF — stwórz od zera
        new_spf="v=spf1 ${FILTERED_INCLUDES[*]} -all"
    else
        # Istniejący SPF — wstaw include'y przed ~all/-all/?all
        base=$(echo "$spf_current" | sed 's/[~\?\+\-]all$//')
        new_spf="${base}${FILTERED_INCLUDES[*]} -all"
    fi

    # Normalizuj spacje
    new_spf=$(echo "$new_spf" | tr -s ' ')

    echo ""
    echo -e "  ${BOLD}Propozycja zmiany SPF:${NC}"
    echo ""
    if [ -n "$spf_current" ]; then
        echo -e "  ${RED}BYŁO:  $spf_current${NC}"
    else
        echo -e "  ${RED}BYŁO:  (brak rekordu)${NC}"
    fi
    echo -e "  ${GREEN}NOWY:  $new_spf${NC}"
    echo ""

    # Ostrzeżenie o liczbie DNS lookups (limit 10)
    lookup_count=$(echo "$new_spf" | grep -o 'include:' | wc -l | tr -d ' ')
    if [ "$lookup_count" -gt 8 ]; then
        warn "Uwaga: $lookup_count include'ów — limit SPF to 10 DNS lookups!"
    fi

    echo -e "  ${YELLOW}⚠️  SPF to krytyczny rekord — błąd może zablokować WSZYSTKIE maile z domeny!${NC}"
    echo ""
    read -p "  Zmienić rekord SPF? (t/N) " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[TtYy]$ ]]; then
        info "Pominięto. Zmień ręcznie w DNS:"
        echo "     $domain  TXT  \"$new_spf\""
        echo ""
        continue
    fi

    # Drugie potwierdzenie
    echo ""
    echo -e "  ${BOLD}${RED}Potwierdzenie — nowy rekord SPF dla $domain:${NC}"
    echo "  $new_spf"
    echo ""
    read -p "  Czy na pewno? Wpisuję TAK żeby potwierdzić: " confirm
    echo ""

    if [ "$confirm" != "TAK" ]; then
        info "Anulowano. Zmień ręcznie w DNS:"
        echo "     $domain  TXT  \"$new_spf\""
        echo ""
        continue
    fi

    if $HAS_CLOUDFLARE; then
        if cf_add_record "$domain" "TXT" "$domain" "$new_spf"; then
            ok "SPF zaktualizowany dla $domain"
        else
            fail "Nie udało się — zmień ręcznie:"
            echo "     $domain  TXT  \"$new_spf\""
        fi
    else
        echo "  Zmień w DNS:"
        echo "  Typ: TXT | Nazwa: $domain | Wartość: $new_spf"
    fi
    echo ""
done

# ─── DKIM ────────────────────────────────────────────────────

step "Krok 2: DKIM — podpis cyfrowy maili"

echo "Każdy dostawca SMTP generuje unikalne rekordy DKIM."
echo "Trzeba je pobrać z panelu dostawcy i dodać w DNS."
echo "Domena może mieć wielu dostawców (np. SES + EmailLabs)."
echo ""

for i in "${!DOMAINS[@]}"; do
    domain="${DOMAINS[$i]}"
    echo -e "  ${BOLD}📧 $domain${NC}"

    if [ "${DKIM_EXISTING[$i]}" = "yes" ]; then
        ok "DKIM już skonfigurowany w Cloudflare"
        if $DRY_RUN; then
            echo ""
            continue
        fi
        read -p "  Dodać kolejne rekordy DKIM (np. dla drugiego SMTP)? (t/N) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[TtYy]$ ]]; then
            echo ""
            continue
        fi
    fi

    if $DRY_RUN; then
        if [ "${DKIM_EXISTING[$i]}" != "yes" ]; then
            warn "Brak DKIM — potrzebne rekordy CNAME/TXT od dostawcy SMTP"
            echo "     Uruchom bez --dry-run żeby dodać interaktywnie"
        fi
        echo ""
        continue
    fi

    while true; do
        echo ""
        echo "  Jaki SMTP wysyła maile z $domain?"
        echo "  1) Amazon SES"
        echo "  2) EmailLabs"
        echo "  3) Inny dostawca (Mailgun, Resend, Brevo, ...)"
        echo "  4) Gotowe / pomiń"
        echo ""
        read -p "  Wybierz (1/2/3/4): " provider_choice
        echo ""

        case "$provider_choice" in
            1) add_dkim_for_provider "$domain" "ses" || true ;;
            2) add_dkim_for_provider "$domain" "emaillabs" || true ;;
            3) add_dkim_for_provider "$domain" "custom" || true ;;
            *) break ;;
        esac

        echo ""
        read -p "  Dodać DKIM dla kolejnego dostawcy na $domain? (t/N) " -n 1 -r
        echo ""
        [[ ! $REPLY =~ ^[TtYy]$ ]] && break
    done

    echo ""
done

# ─── DMARC ──────────────────────────────────────────────────

step "Krok 3: DMARC — polityka ochrony domeny"

echo "DMARC mówi serwerom co robić z mailami bez podpisu."
echo "Zaczynamy od p=none (monitoring) — zbiera raporty, nic nie blokuje."
echo "Po 2-4 tygodniach zaostrzysz do p=quarantine (spam)."
echo ""

# Skonsolidowany email do raportów
if [ ${#DOMAINS[@]} -gt 1 ] && ! $DRY_RUN; then
    echo "Masz ${#DOMAINS[@]} domeny. Raporty DMARC mogą trafiać na jeden adres."
    echo "Np. dmarc@mojafirma.pl zamiast osobnego na każdej domenie."
    echo ""
    read -p "Email do raportów DMARC (Enter = osobny per domena): " DMARC_REPORT_EMAIL
    echo ""
fi

for i in "${!DOMAINS[@]}"; do
    domain="${DOMAINS[$i]}"

    if [ "${DMARC_RESULTS[$i]}" = "OK" ]; then
        ok "$domain — DMARC już skonfigurowany"
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
    echo "  Rekord: $dmarc_name  TXT  \"$dmarc_value\""
    echo ""

    if $HAS_CLOUDFLARE; then
        if ! $DRY_RUN; then
            read -p "  Dodać automatycznie przez Cloudflare? (T/n) " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                echo ""
                continue
            fi
        fi
        if cf_add_record "$domain" "TXT" "$dmarc_name" "$dmarc_value"; then
            if $DRY_RUN; then
                info "DMARC: zostanie dodany dla $domain"
            else
                ok "DMARC dodany dla $domain"
            fi
            DMARC_ADDED=true
        else
            fail "Nie udało się — dodaj ręcznie:"
            echo "     Typ: TXT | Nazwa: $dmarc_name | Wartość: $dmarc_value"
        fi
    else
        echo "  Dodaj w DNS (Cloudflare):"
        echo "  Typ: TXT | Nazwa: $dmarc_name"
        echo "  Wartość: $dmarc_value"
    fi
    echo ""
done

# Cross-domain DMARC auth records
if [ -n "$DMARC_REPORT_EMAIL" ]; then
    report_domain="${DMARC_REPORT_EMAIL#*@}"

    echo -e "  ${BOLD}Cross-domain DMARC reporting:${NC}"
    echo ""
    echo "  Raporty z wielu domen trafiają do $DMARC_REPORT_EMAIL."
    echo "  Każda domena (poza $report_domain) potrzebuje rekordu autoryzacji."
    echo ""

    for domain in "${DOMAINS[@]}"; do
        [ "$domain" = "$report_domain" ] && continue

        auth_name="${report_domain}._report._dmarc.${domain}"
        auth_value="v=DMARC1"

        echo "  $auth_name  TXT  \"$auth_value\""

        if $HAS_CLOUDFLARE; then
            if cf_add_record "$domain" "TXT" "$auth_name" "$auth_value"; then
                ok "Auth record: $domain → $report_domain"
            else
                fail "Nie udało się dodać auth record"
                echo "     Dodaj ręcznie w strefie $domain:"
                echo "     Typ: TXT | Nazwa: $auth_name | Wartość: $auth_value"
            fi
        else
            echo "     Dodaj w strefie DNS $domain:"
            echo "     Typ: TXT | Nazwa: $auth_name | Wartość: $auth_value"
        fi
    done
    echo ""
fi

# ─── Weryfikacja DNS ─────────────────────────────────────────

if $HAS_CLOUDFLARE && { [ ${#DKIM_ADDED_NAMES[@]} -gt 0 ] || $DMARC_ADDED; }; then
    step "Weryfikacja DNS"

    echo "Sprawdzam propagację (Cloudflare = zwykle natychmiastowa)..."
    echo ""
    $DRY_RUN || sleep 2

    for name in "${DKIM_ADDED_NAMES[@]}"; do
        result=$(dig CNAME "$name" +short 2>/dev/null || true)
        [ -z "$result" ] && result=$(dig TXT "$name" +short 2>/dev/null | tr -d '"' || true)
        if [ -n "$result" ]; then
            ok "DKIM: $name → $(echo "$result" | head -1)"
        else
            warn "DKIM: $name — jeszcze nie widoczny (poczekaj 1-5 min)"
        fi
    done

    for domain in "${DOMAINS[@]}"; do
        dmarc=$(dig TXT "_dmarc.$domain" +short 2>/dev/null | tr -d '"' || true)
        if echo "$dmarc" | grep -qi 'DMARC1'; then
            ok "DMARC: _dmarc.$domain"
        fi
    done
    echo ""
fi

# ─── Bounce handling (SES) ───────────────────────────────────

step "Krok 4: Bounce handling — ochrona reputacji"

echo "Bounce handling automatycznie blokuje nieistniejące adresy email."
echo "Bez tego Amazon SES może zawiesić konto po zbyt wielu bounce'ach."
echo ""

if [ -n "$WEBHOOK_URL" ]; then
    echo -e "${BOLD}Konfiguracja AWS SNS → webhook:${NC}"
    echo ""
    echo "  Dla każdej domeny potrzebujesz osobne SNS topics (bounce + complaint)."
    echo ""
    echo "  1. AWS SNS Console → Create topic (dla każdej domeny × 2):"
    for domain in "${DOMAINS[@]}"; do
        prefix=$(echo "$domain" | cut -d. -f1 | head -c10)
        echo "     • ${prefix}-ses-bounces    (Standard)"
        echo "     • ${prefix}-ses-complaints (Standard)"
    done
    echo ""
    echo "  2. W każdym topiku → Create subscription:"
    echo "     • Protocol: HTTPS"
    echo "     • Endpoint: $WEBHOOK_URL"
    echo "     Mailer automatycznie potwierdzi subskrypcję."
    echo ""
    echo "  3. AWS SES Console → Verified Identities → każda domena:"
    echo "     • Notifications → Edit"
    echo "     • Bounce: wybierz odpowiedni topic *-bounces"
    echo "     • Complaint: wybierz odpowiedni topic *-complaints"
    echo ""

    open_url "https://console.aws.amazon.com/sns/v3/home#/topics"

    if ! $DRY_RUN; then
        read -p "Naciśnij Enter gdy skonfigurujesz SNS (lub 's' żeby pominąć): " _skip
        echo ""
    fi
else
    echo "  Jeśli używasz Amazon SES, skonfiguruj bounce handling:"
    echo "  • Utwórz SNS topics (bounce + complaint) per domena"
    echo "  • Dodaj subscription HTTPS → webhook URL Twojego mailera"
    echo "  • W SES → domena → Notifications → podepnij topics"
    echo ""
    echo "  Użyj --webhook-url=URL żeby zobaczyć pełne instrukcje."
    echo ""
fi

# ─── Podsumowanie ────────────────────────────────────────────

step "Podsumowanie — konfiguracja DNS"

echo "┌──────────────────────────────────────────────────────────┐"
echo "│  Co zostało zrobione:                                    │"
echo "├──────────────────────────────────────────────────────────┤"
if [ ${#DKIM_ADDED_NAMES[@]} -gt 0 ]; then
echo "│  ✅ DKIM — rekordy DNS dodane                            │"
elif [ -n "$(printf '%s' "${DKIM_EXISTING[@]}" | grep yes)" ]; then
echo "│  ✅ DKIM — rekordy już istniały                          │"
else
echo "│  ⚠️  DKIM — sprawdź czy rekordy zostały dodane            │"
fi
DMARC_ALL_OK=true
for i in "${!DOMAINS[@]}"; do
    [ "${DMARC_RESULTS[$i]}" != "OK" ] && ! $DMARC_ADDED && DMARC_ALL_OK=false
done
if $DMARC_ADDED; then
echo "│  ✅ DMARC — polityka p=none (monitoring)                 │"
elif $DMARC_ALL_OK; then
echo "│  ✅ DMARC — rekordy już istniały                          │"
else
echo "│  ⚠️  DMARC — sprawdź czy rekord został dodany             │"
fi
if [ -n "$DMARC_REPORT_EMAIL" ]; then
echo "│  ✅ DMARC auth — cross-domain reporting                  │"
fi
echo "└──────────────────────────────────────────────────────────┘"
echo ""
echo -e "${BOLD}📋 Następne kroki:${NC}"
echo ""
echo "  1. Wyślij testowego maila i sprawdź nagłówki:"
echo "     Szukaj: dkim=pass, spf=pass, dmarc=pass"
echo "     Narzędzie: https://www.mail-tester.com"
echo ""
echo "  2. Za 2-4 tygodnie zaaostrzyj DMARC:"
for domain in "${DOMAINS[@]}"; do
    rua_email="${DMARC_REPORT_EMAIL:-dmarc-reports@$domain}"
    echo "     _dmarc.$domain → \"v=DMARC1; p=quarantine; rua=mailto:$rua_email\""
done
echo ""
if [ -n "$DMARC_REPORT_EMAIL" ]; then
echo "  3. Utwórz alias $DMARC_REPORT_EMAIL — inaczej raporty nie mają gdzie trafiać"
echo ""
fi
echo "  4. Upewnij się że wszystkie domeny mają SPF -all (nie ~all)"
echo ""
