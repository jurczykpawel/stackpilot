#!/bin/bash

# Mikrus Toolbox - Listmonk Mail Setup
# Wrapper na setup-mail-domain.sh + konfiguracja Listmonk API.
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   ./local/setup-listmonk-mail.sh [DOMENY...] [--listmonk-url=URL] [--ssh=ALIAS]
#
# Przykłady:
#   ./local/setup-listmonk-mail.sh mojafirma.pl sklep.mojafirma.pl
#   ./local/setup-listmonk-mail.sh --listmonk-url=https://newsletter.mojafirma.pl --ssh=mikrus

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kolory
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✅ $1${NC}"; }
fail() { echo -e "  ${RED}❌ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
info() { echo -e "  ${CYAN}ℹ️  $1${NC}"; }
step() { echo ""; echo -e "${BOLD}── $1 ──────────────────────────────────────────${NC}"; echo ""; }

# Parsuj argumenty — wyciągnij Listmonk-specific, resztę przekaż dalej
LISTMONK_URL=""
LISTMONK_USER=""
LISTMONK_PASS=""
SSH_ALIAS=""
DRY_RUN=false
GENERIC_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --listmonk-url=*) LISTMONK_URL="${arg#*=}" ;;
        --ssh=*) SSH_ALIAS="${arg#*=}" ;;
        --dry-run) DRY_RUN=true; GENERIC_ARGS+=("$arg") ;;
        --help|-h)
            echo "Użycie: $0 [DOMENY...] [--listmonk-url=URL] [--ssh=ALIAS]"
            echo ""
            echo "Konfiguruje domeny (DKIM, DMARC) + Listmonk (bounce, powiadomienia)."
            echo ""
            echo "Opcje:"
            echo "  --listmonk-url=URL   URL instancji Listmonk"
            echo "  --ssh=ALIAS          SSH alias (restart Listmonka po zmianach)"
            echo ""
            echo "Przykłady:"
            echo "  $0 mojafirma.pl sklep.mojafirma.pl"
            echo "  $0 --listmonk-url=https://newsletter.mojafirma.pl --ssh=mikrus"
            echo ""
            echo "Skrypt łączy:"
            echo "  1. setup-mail-domain.sh — konfiguracja DNS (SPF, DKIM, DMARC)"
            echo "  2. Listmonk API — bounce handling + powiadomienia"
            echo "  3. Restart Listmonka via SSH"
            exit 0
            ;;
        *) GENERIC_ARGS+=("$arg") ;;
    esac
done

# ─── Krok 1: Konfiguracja DNS (generic) ─────────────────────

WEBHOOK_URL=""
if [ -n "$LISTMONK_URL" ]; then
    LISTMONK_URL="${LISTMONK_URL%/}"
    WEBHOOK_URL="${LISTMONK_URL}/webhooks/service/ses"
fi

MAIL_DOMAIN_ARGS=("${GENERIC_ARGS[@]}")
[ -n "$WEBHOOK_URL" ] && MAIL_DOMAIN_ARGS+=("--webhook-url=$WEBHOOK_URL")

"$SCRIPT_DIR/setup-mail-domain.sh" "${MAIL_DOMAIN_ARGS[@]}"

# ─── Krok 2: Konfiguracja Listmonk API ──────────────────────

step "Konfiguracja Listmonka (API)"

LISTMONK_CONFIGURED=false

if $DRY_RUN; then
    info "[DRY-RUN] Pominięto konfigurację Listmonk API"
    if [ -n "$LISTMONK_URL" ]; then
        info "Bounce handling: SES webhook ON, count=1, action=blocklist"
        info "Powiadomienia: skonfigurowane na podany email"
        [ -n "$SSH_ALIAS" ] && info "Restart Listmonka na '$SSH_ALIAS'"
    fi
else

echo "Skonfiguruję bounce handling i powiadomienia przez Listmonk API."
echo ""

if [ -z "$LISTMONK_URL" ]; then
    read -p "URL Listmonka (np. https://newsletter.mojafirma.pl) lub Enter żeby pominąć: " LISTMONK_URL
    LISTMONK_URL="${LISTMONK_URL%/}"
fi

if [ -n "$LISTMONK_URL" ]; then
    [ -z "$LISTMONK_USER" ] && read -p "Login (domyślnie: admin): " LISTMONK_USER
    LISTMONK_USER="${LISTMONK_USER:-admin}"
    [ -z "$LISTMONK_PASS" ] && { read -s -p "Hasło: " LISTMONK_PASS; echo ""; }
    echo ""

    # Test połączenia
    echo "Testuję połączenie z $LISTMONK_URL..."
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${LISTMONK_USER}:${LISTMONK_PASS}" \
        "${LISTMONK_URL}/api/settings" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
        ok "Połączenie OK"
        echo ""

        # Bounce handling
        echo -e "  ${BOLD}Bounce handling:${NC}"
        echo "  • SES bounce webhook: ON"
        echo "  • Hard bounce po 1 zdarzeniu → blocklist"
        echo "  • Complaint po 1 zdarzeniu → blocklist"
        echo ""

        read -p "  Włączyć? (T/n) " -n 1 -r
        echo ""

        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            bounce_response=$(curl -s -X PUT "${LISTMONK_URL}/api/settings" \
                -u "${LISTMONK_USER}:${LISTMONK_PASS}" \
                -H "Content-Type: application/json" \
                -d '[
                    {"key":"bounce.enabled","value":true},
                    {"key":"bounce.webhooks_enabled","value":true},
                    {"key":"bounce.count","value":1},
                    {"key":"bounce.action","value":"blocklist"},
                    {"key":"bounce.ses_enabled","value":true},
                    {"key":"bounce.sendgrid_enabled","value":false},
                    {"key":"bounce.postmark_enabled","value":false}
                ]' 2>/dev/null || true)

            if echo "$bounce_response" | grep -q '"data"'; then
                ok "Bounce handling włączony"
                LISTMONK_CONFIGURED=true
            else
                warn "Nie udało się przez API — skonfiguruj ręcznie:"
                echo "     Settings → Bounces → Enable SES, count=1, action=blocklist"
            fi
        fi
        echo ""

        # Powiadomienia
        echo -e "  ${BOLD}Powiadomienia email:${NC}"
        echo "  (zakończone kampanie, błędy importu, bounce raporty)"
        echo ""
        read -p "  Email do powiadomień: " notify_email

        if [ -n "$notify_email" ]; then
            notify_response=$(curl -s -X PUT "${LISTMONK_URL}/api/settings" \
                -u "${LISTMONK_USER}:${LISTMONK_PASS}" \
                -H "Content-Type: application/json" \
                -d "[{\"key\":\"app.notify_emails\",\"value\":[\"$notify_email\"]}]" 2>/dev/null || true)

            if echo "$notify_response" | grep -q '"data"'; then
                ok "Powiadomienia → $notify_email"
                LISTMONK_CONFIGURED=true
            else
                warn "Nie udało się — ustaw ręcznie:"
                echo "     Settings → General → Notification emails: $notify_email"
            fi
        fi
    else
        fail "Nie mogę się połączyć (HTTP $http_code)"
        echo ""
        echo "  Skonfiguruj ręcznie w panelu Listmonka:"
        echo "  • Settings → Bounces → Enable SES bounces, count=1, action=blocklist"
        echo "  • Settings → General → Notification emails"
    fi
else
    echo "  Pominięto. Skonfiguruj ręcznie:"
    echo "  • Settings → Bounces → Enable SES bounces, count=1, action=blocklist"
    echo "  • Settings → General → Notification emails"
fi

fi  # koniec if ! $DRY_RUN

# ─── Krok 3: Restart Listmonka ──────────────────────────────

if $LISTMONK_CONFIGURED; then
    echo ""
    echo -e "  ${BOLD}Restart Listmonka:${NC}"
    echo "  Po zmianach ustawień Listmonk wymaga restartu."
    echo ""

    if [ -n "$SSH_ALIAS" ]; then
        read -p "  Zrestartować na '$SSH_ALIAS'? (T/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo "  Restartuję..."
            if ssh "$SSH_ALIAS" 'cd /opt/stacks/listmonk && docker compose restart' 2>/dev/null; then
                ok "Listmonk zrestartowany"
            else
                fail "Nie udało się"
                echo "     ssh $SSH_ALIAS 'cd /opt/stacks/listmonk && docker compose restart'"
            fi
        fi
    else
        warn "Brak --ssh=ALIAS — zrestartuj ręcznie:"
        echo "     ssh SERWER 'cd /opt/stacks/listmonk && docker compose restart'"
    fi
fi

# ─── Podsumowanie Listmonk ──────────────────────────────────

step "Listmonk — status"

if $LISTMONK_CONFIGURED; then
    ok "Bounce handling + powiadomienia — skonfigurowane"
else
    warn "Bounce handling + powiadomienia — wymaga ręcznej konfiguracji"
fi

if [ -n "$LISTMONK_URL" ]; then
    echo ""
    echo "  Panel: $LISTMONK_URL"
    echo "  Webhook: ${LISTMONK_URL}/webhooks/service/ses"
fi
echo ""
echo "✅ Gotowe!"
echo ""
