#!/bin/bash

# StackPilot - Mikrus Provider: Cytrus Domain Registration
# Registers domains via Mikrus Cytrus API.
# Supports *.byst.re, *.bieda.it, *.toadres.pl, *.tojest.dev auto-domains.

# =============================================================================
# cytrus_register_domain DOMAIN PORT [SSH_ALIAS]
#
# DOMAIN: full domain (e.g. myapp.byst.re) or "-" for automatic assignment
# PORT:   local port the app listens on
# SSH_ALIAS: SSH alias for the server (default: vps)
# =============================================================================

cytrus_register_domain() {
    local FULL_DOMAIN="${1:--}"
    local PORT="$2"
    local SSH_ALIAS="${3:-${SSH_ALIAS:-vps}}"

    echo ""
    msg "$MSG_CYTRUS_HEADER"
    echo ""
    if [ "$FULL_DOMAIN" = "-" ]; then
        msg "$MSG_CYTRUS_DOMAIN_AUTO"
    else
        msg "$MSG_CYTRUS_DOMAIN_SET" "$FULL_DOMAIN"
    fi
    msg "$MSG_CYTRUS_PORT" "$PORT"
    msg "$MSG_CYTRUS_SERVER" "$SSH_ALIAS"
    echo ""

    # Check if it's a supported domain or auto
    if [ "$FULL_DOMAIN" != "-" ] && \
       [[ "$FULL_DOMAIN" != *".byst.re" ]] && \
       [[ "$FULL_DOMAIN" != *".bieda.it" ]] && \
       [[ "$FULL_DOMAIN" != *".toadres.pl" ]] && \
       [[ "$FULL_DOMAIN" != *".tojest.dev" ]]; then
        msg "$MSG_CYTRUS_WARN_CUSTOM"
        msg "$MSG_CYTRUS_WARN_DNS"
        msg "$MSG_CYTRUS_WARN_PANEL"
        echo ""
        msg "$MSG_CYTRUS_WARN_CF"
        msg "$MSG_CYTRUS_WARN_CF2"
        echo ""
        read -p "$(msg "$MSG_CYTRUS_CONTINUE")" CONTINUE
        if [[ ! "$CONTINUE" =~ ^[TtYy]$ ]]; then
            msg "$MSG_CYTRUS_ABORTED"
            return 0
        fi
    fi

    # 1. Fetch API key from server
    msg "$MSG_CYTRUS_FETCHING_KEY"
    local API_KEY
    API_KEY=$(server_exec 'cat /klucz_api 2>/dev/null' 2>/dev/null)

    if [ -z "$API_KEY" ]; then
        msg "$MSG_CYTRUS_NO_KEY"
        msg "$MSG_CYTRUS_NO_KEY2"
        echo ""
        msg "$MSG_CYTRUS_NO_KEY3"
        msg "$MSG_CYTRUS_NO_KEY4"
        return 1
    fi

    msg "$MSG_CYTRUS_KEY_OK"
    echo ""

    # 2. Fetch server identifier (hostname)
    msg "$MSG_CYTRUS_FETCHING_SRV"
    local SRV
    SRV=$(server_exec 'hostname' 2>/dev/null)

    if [ -z "$SRV" ]; then
        msg "$MSG_CYTRUS_SRV_FAIL"
        return 1
    fi

    msg "$MSG_CYTRUS_SRV_OK" "$SRV"
    echo ""

    # 3. Call Mikrus API
    msg "$MSG_CYTRUS_REGISTERING"

    local RESPONSE
    RESPONSE=$(curl -s -X POST "https://api.mikr.us/domain" \
        -d "key=$API_KEY" \
        -d "srv=$SRV" \
        -d "domain=$FULL_DOMAIN" \
        -d "port=$PORT")

    # 4. Parse response
    if echo "$RESPONSE" | grep -qi '"status".*gotowe\|"domain"'; then
        # Extract assigned domain if auto
        local ASSIGNED_DOMAIN
        ASSIGNED_DOMAIN=$(echo "$RESPONSE" | sed -n 's/.*"domain"\s*:\s*"\([^"]*\)".*/\1/p')

        if [ "$FULL_DOMAIN" = "-" ] && [ -n "$ASSIGNED_DOMAIN" ]; then
            FULL_DOMAIN="$ASSIGNED_DOMAIN"
        fi

        echo ""
        msg "$MSG_CYTRUS_OK"
        echo ""
        msg "$MSG_CYTRUS_LIVE"
        msg "$MSG_CYTRUS_URL" "$FULL_DOMAIN"
        echo ""

        if [[ "$FULL_DOMAIN" == *".byst.re" ]] || \
           [[ "$FULL_DOMAIN" == *".bieda.it" ]] || \
           [[ "$FULL_DOMAIN" == *".toadres.pl" ]] || \
           [[ "$FULL_DOMAIN" == *".tojest.dev" ]]; then
            msg "$MSG_CYTRUS_INSTANT"
        else
            msg "$MSG_CYTRUS_DNS_NEEDED"
            msg "$MSG_CYTRUS_DNS_TYPE"
            msg "$MSG_CYTRUS_DNS_NAME" "$(echo "$FULL_DOMAIN" | cut -d. -f1)"
            msg "$MSG_CYTRUS_DNS_VALUE"
        fi
        echo ""

    elif echo "$RESPONSE" | grep -qiE "już istnieje|ju.*istnieje|already exists"; then
        echo ""
        msg "$MSG_CYTRUS_TAKEN" "$FULL_DOMAIN"
        echo ""
        msg "$MSG_CYTRUS_TAKEN_TIP"
        msg "$MSG_CYTRUS_TAKEN_ALT1" "${FULL_DOMAIN%%.*}-2.${FULL_DOMAIN#*.}"
        msg "$MSG_CYTRUS_TAKEN_ALT2" "my-${FULL_DOMAIN}"
        echo ""
        msg "$MSG_CYTRUS_TAKEN_RETRY"
        return 1

    elif echo "$RESPONSE" | grep -qi "error\|błąd\|fail"; then
        echo ""
        msg "$MSG_CYTRUS_API_ERR"
        msg "$MSG_CYTRUS_API_ERR2" "$RESPONSE"
        echo ""
        msg "$MSG_CYTRUS_API_CHECK"
        msg "$MSG_CYTRUS_API_CHECK1"
        msg "$MSG_CYTRUS_API_CHECK2"
        msg "$MSG_CYTRUS_API_CHECK3"
        return 1
    else
        echo ""
        msg "$MSG_CYTRUS_API_UNKNOWN"
        msg "$MSG_CYTRUS_API_UNKNOWN2" "$RESPONSE"
        echo ""
        msg "$MSG_CYTRUS_API_VERIFY"
        msg "$MSG_CYTRUS_API_VERIFY2"
    fi
}

export -f cytrus_register_domain
