#!/bin/bash

# StackPilot - Listmonk Mail Setup
# Wrapper for setup-mail-domain.sh + Listmonk API configuration.
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/setup-listmonk-mail.sh [DOMAINS...] [--listmonk-url=URL] [--ssh=ALIAS]
#
# Examples:
#   ./local/setup-listmonk-mail.sh mycompany.com shop.mycompany.com
#   ./local/setup-listmonk-mail.sh --listmonk-url=https://newsletter.mycompany.com --ssh=vps

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors (before i18n so they are available in MSG_ strings)
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
BLUE='\033[0;34m'

# i18n
_LM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_LM_DIR/../lib/i18n.sh"
fi

ok()   { echo -e "  ${GREEN}✅ $1${NC}"; }
fail() { echo -e "  ${RED}❌ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
info() { echo -e "  ${CYAN}ℹ️  $1${NC}"; }
step() { echo ""; echo -e "${BOLD}── $1 ──────────────────────────────────────────${NC}"; echo ""; }

# Parse arguments — extract Listmonk-specific, pass the rest through
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
            msg "$MSG_LM_HELP_USAGE" "$0"
            echo ""
            msg "$MSG_LM_HELP_DESC"
            echo ""
            msg "$MSG_LM_HELP_OPTS"
            msg "$MSG_LM_HELP_OPT_URL"
            msg "$MSG_LM_HELP_OPT_SSH"
            echo ""
            msg "$MSG_LM_HELP_EX_1" "$0"
            msg "$MSG_LM_HELP_EX_2" "$0"
            echo ""
            msg "$MSG_LM_HELP_COMBINES"
            msg "$MSG_LM_HELP_STEP1"
            msg "$MSG_LM_HELP_STEP2"
            msg "$MSG_LM_HELP_STEP3"
            exit 0
            ;;
        *) GENERIC_ARGS+=("$arg") ;;
    esac
done

# ─── Step 1: DNS configuration (generic) ─────────────────────

WEBHOOK_URL=""
if [ -n "$LISTMONK_URL" ]; then
    LISTMONK_URL="${LISTMONK_URL%/}"
    WEBHOOK_URL="${LISTMONK_URL}/webhooks/service/ses"
fi

MAIL_DOMAIN_ARGS=("${GENERIC_ARGS[@]}")
[ -n "$WEBHOOK_URL" ] && MAIL_DOMAIN_ARGS+=("--webhook-url=$WEBHOOK_URL")

"$SCRIPT_DIR/setup-mail-domain.sh" "${MAIL_DOMAIN_ARGS[@]}"

# ─── Step 2: Listmonk API configuration ──────────────────────

step "$(msg_n "$MSG_LM_API_STEP")"

LISTMONK_CONFIGURED=false

if $DRY_RUN; then
    msg "$MSG_LM_API_DRYRUN"
    if [ -n "$LISTMONK_URL" ]; then
        msg "$MSG_LM_API_DRYRUN_BOUNCE"
        msg "$MSG_LM_API_DRYRUN_NOTIFY"
        [ -n "$SSH_ALIAS" ] && msg "$MSG_LM_API_DRYRUN_RESTART" "$SSH_ALIAS"
    fi
else

msg "$MSG_LM_API_INTRO"
echo ""

if [ -z "$LISTMONK_URL" ]; then
    read -p "$(msg_n "$MSG_LM_API_URL_PROMPT")" LISTMONK_URL
    LISTMONK_URL="${LISTMONK_URL%/}"
fi

if [ -n "$LISTMONK_URL" ]; then
    [ -z "$LISTMONK_USER" ] && read -p "$(msg_n "$MSG_LM_API_USER_PROMPT")" LISTMONK_USER
    LISTMONK_USER="${LISTMONK_USER:-admin}"
    [ -z "$LISTMONK_PASS" ] && { read -s -p "$(msg_n "$MSG_LM_API_PASS_PROMPT")" LISTMONK_PASS; echo ""; }
    echo ""

    # Test connection
    msg "$MSG_LM_API_CONNECTING" "$LISTMONK_URL"
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${LISTMONK_USER}:${LISTMONK_PASS}" \
        "${LISTMONK_URL}/api/settings" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
        msg "$MSG_LM_API_OK"
        echo ""

        # Bounce handling
        msg "$MSG_LM_API_BOUNCE_HEADER"
        msg "$MSG_LM_API_BOUNCE_SES"
        msg "$MSG_LM_API_BOUNCE_HARD"
        msg "$MSG_LM_API_BOUNCE_COMP"
        echo ""

        read -p "$(msg_n "$MSG_LM_API_BOUNCE_ENABLE")" -n 1 -r
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
                msg "$MSG_LM_API_BOUNCE_OK"
                LISTMONK_CONFIGURED=true
            else
                msg "$MSG_LM_API_BOUNCE_WARN"
                msg "$MSG_LM_API_BOUNCE_MANUAL"
            fi
        fi
        echo ""

        # Notifications
        msg "$MSG_LM_API_NOTIFY_HEADER"
        msg "$MSG_LM_API_NOTIFY_DESC"
        echo ""
        read -p "$(msg_n "$MSG_LM_API_NOTIFY_PROMPT")" notify_email

        if [ -n "$notify_email" ]; then
            notify_response=$(curl -s -X PUT "${LISTMONK_URL}/api/settings" \
                -u "${LISTMONK_USER}:${LISTMONK_PASS}" \
                -H "Content-Type: application/json" \
                -d "[{\"key\":\"app.notify_emails\",\"value\":[\"$notify_email\"]}]" 2>/dev/null || true)

            if echo "$notify_response" | grep -q '"data"'; then
                msg "$MSG_LM_API_NOTIFY_OK" "$notify_email"
                LISTMONK_CONFIGURED=true
            else
                msg "$MSG_LM_API_NOTIFY_WARN"
                msg "$MSG_LM_API_NOTIFY_MANUAL" "$notify_email"
            fi
        fi
    else
        msg "$MSG_LM_API_CONN_FAIL" "$http_code"
        echo ""
        echo "  $(msg_n "$MSG_LM_API_SKIP")"
        msg "$MSG_LM_API_MANUAL_BOUNCES"
        msg "$MSG_LM_API_MANUAL_NOTIFY"
    fi
else
    msg "$MSG_LM_API_SKIP"
    msg "$MSG_LM_API_MANUAL_BOUNCES"
    msg "$MSG_LM_API_MANUAL_NOTIFY"
fi

fi  # end if ! $DRY_RUN

# ─── Step 3: Restart Listmonk ────────────────────────────────

if $LISTMONK_CONFIGURED; then
    echo ""
    msg "$MSG_LM_RESTART_HEADER"
    msg "$MSG_LM_RESTART_NEEDED"
    echo ""

    if [ -n "$SSH_ALIAS" ]; then
        read -p "$(msg_n "$MSG_LM_RESTART_PROMPT" "$SSH_ALIAS")" -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            msg "$MSG_LM_RESTART_ING"
            if ssh "$SSH_ALIAS" 'cd /opt/stacks/listmonk && docker compose restart' 2>/dev/null; then
                msg "$MSG_LM_RESTART_OK"
            else
                msg "$MSG_LM_RESTART_FAIL"
                msg "$MSG_LM_RESTART_FAIL_CMD" "$SSH_ALIAS"
            fi
        fi
    else
        msg "$MSG_LM_RESTART_NO_SSH"
        msg "$MSG_LM_RESTART_NO_SSH_CMD"
    fi
fi

# ─── Listmonk summary ────────────────────────────────────────

step "$(msg_n "$MSG_LM_STATUS_STEP")"

if $LISTMONK_CONFIGURED; then
    msg "$MSG_LM_STATUS_OK"
else
    msg "$MSG_LM_STATUS_WARN"
fi

if [ -n "$LISTMONK_URL" ]; then
    echo ""
    msg "$MSG_LM_STATUS_PANEL" "$LISTMONK_URL"
    msg "$MSG_LM_STATUS_WEBHOOK" "$LISTMONK_URL"
fi
echo ""
msg "$MSG_LM_DONE"
echo ""
