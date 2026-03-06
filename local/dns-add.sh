#!/bin/bash

# StackPilot - Cloudflare DNS Add
# Adds a DNS record to Cloudflare (A or AAAA).
# Requires prior configuration: ./local/setup-cloudflare.sh
# Author: Paweł (Lazy Engineer)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

# i18n guard (server-exec.sh already loads it)
_DNS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TOOLBOX_LANG+x}" ]; then
    source "$_DNS_DIR/../lib/i18n.sh"
fi

CONFIG_FILE="$HOME/.config/cloudflare/config"

# Arguments
FULL_DOMAIN="$1"
SSH_ALIAS="${2:-vps}"

# Usage
if [ -z "$FULL_DOMAIN" ]; then
    echo "Usage: $0 <subdomain.domain.com> [ssh_alias]"
    echo ""
    echo "Examples:"
    echo "  $0 app.mycompany.com                    # Cloudflare + Caddy"
    echo "  $0 app.mycompany.com vps                # from a different server"
    echo ""
    echo "Requires prior configuration: ./local/setup-cloudflare.sh"
    exit 1
fi

# Determine record type and IP
RECORD_TYPE="AAAA"
PROXY="true"
msg "$MSG_DNS_CF_MODE"
msg "$MSG_DNS_FETCH_IPV6" "$SSH_ALIAS"
    IP_ADDRESS=$(server_exec "ip -6 addr show scope global | grep -oP '(?<=inet6 )[0-9a-f:]+' | head -1" 2>/dev/null)

if [ -z "$IP_ADDRESS" ]; then
    msg "$MSG_DNS_NO_IPV6" "$SSH_ALIAS"
    exit 1
fi
msg "$MSG_DNS_RECORD" "$IP_ADDRESS"
msg "$MSG_DNS_PROXY"
echo ""

# Check configuration
if [ ! -f "$CONFIG_FILE" ]; then
    msg "$MSG_DNS_NO_CONFIG"
    msg "$MSG_DNS_NO_CONFIG_HINT"
    exit 1
fi

# Load token
API_TOKEN=$(grep "^API_TOKEN=" "$CONFIG_FILE" | cut -d= -f2)

if [ -z "$API_TOKEN" ]; then
    msg "$MSG_DNS_NO_TOKEN"
    exit 1
fi

# Extract root domain from full subdomain
ROOT_DOMAIN=$(echo "$FULL_DOMAIN" | rev | cut -d. -f1-2 | rev)
SUBDOMAIN=$(echo "$FULL_DOMAIN" | sed "s/\.$ROOT_DOMAIN$//")

if [ "$SUBDOMAIN" = "$ROOT_DOMAIN" ]; then
    SUBDOMAIN="@"
fi

msg "$MSG_DNS_ROOT_DOMAIN" "$ROOT_DOMAIN"
msg "$MSG_DNS_SUBDOMAIN" "$SUBDOMAIN"
echo ""

# Find Zone ID
ZONE_ID=$(grep "^${ROOT_DOMAIN}=" "$CONFIG_FILE" | cut -d= -f2)

if [ -z "$ZONE_ID" ]; then
    msg "$MSG_DNS_NO_ZONE" "$ROOT_DOMAIN"
    msg "$MSG_DNS_NO_ZONE_AVAIL"
    grep -v "^#" "$CONFIG_FILE" | grep -v "API_TOKEN" | grep "=" || msg "$MSG_DNS_NO_ZONE_NONE"
    echo ""
    msg "$MSG_DNS_NO_ZONE_HINT"
    exit 1
fi

msg "$MSG_DNS_ZONE_ID" "$ZONE_ID"
echo ""

# Check if record already exists
msg "$MSG_DNS_CHECKING"
EXISTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$RECORD_TYPE&name=$FULL_DOMAIN" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json")

EXISTING_ID=$(echo "$EXISTING" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//g' | sed 's/"//g')

if [ -n "$EXISTING_ID" ]; then
    msg "$MSG_DNS_EXISTS_WARN" "$RECORD_TYPE" "$FULL_DOMAIN"
    EXISTING_IP=$(echo "$EXISTING" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//g' | sed 's/"//g')
    msg "$MSG_DNS_EXISTS_IP" "$EXISTING_IP"

    # If IP is the same - do nothing, success
    if [ "$EXISTING_IP" = "$IP_ADDRESS" ]; then
        msg "$MSG_DNS_SAME_IP"
        exit 0
    fi

    # Ask only when terminal is interactive
    if [ -t 0 ]; then
        echo ""
        read -p "$(msg_n "$MSG_DNS_UPDATE_PROMPT" "$IP_ADDRESS")" -n 1 -r
        echo ""
    else
        msg "$MSG_DNS_NONINTERACTIVE"
        exit 0
    fi

    if [[ $REPLY =~ ^[TtYy]$ ]]; then
        UPDATE_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$EXISTING_ID" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$FULL_DOMAIN\",\"content\":\"$IP_ADDRESS\",\"ttl\":3600,\"proxied\":$PROXY}")

        if echo "$UPDATE_RESPONSE" | grep -q '"success":true'; then
            msg "$MSG_DNS_UPDATED"
        else
            msg "$MSG_DNS_UPDATE_FAIL"
            echo "$UPDATE_RESPONSE"
            exit 1
        fi
    else
        msg "$MSG_CANCELLED"
        exit 0
    fi
else
    msg "$MSG_DNS_CREATING" "$RECORD_TYPE"
    CREATE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$FULL_DOMAIN\",\"content\":\"$IP_ADDRESS\",\"ttl\":3600,\"proxied\":$PROXY}")

    if echo "$CREATE_RESPONSE" | grep -q '"success":true'; then
        msg "$MSG_DNS_CREATED"
    else
        msg "$MSG_DNS_CREATE_FAIL"
        echo "$CREATE_RESPONSE"
        exit 1
    fi
fi

echo ""
msg "$MSG_DNS_SUCCESS" "$FULL_DOMAIN" "$IP_ADDRESS" "$RECORD_TYPE"

msg "$MSG_DNS_PROXY_ENABLED"
echo ""
msg "$MSG_DNS_NEXT_STEP"
msg "$MSG_DNS_NEXT_CMD" "$SSH_ALIAS" "$FULL_DOMAIN"

echo ""
msg "$MSG_DNS_PROPAGATION"
echo ""
