#!/bin/bash

# StackPilot - Cloudflare DNS Add
# Adds a DNS record to Cloudflare (A or AAAA).
# Requires prior configuration: ./local/setup-cloudflare.sh
# Author: Paweł (Lazy Engineer)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

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
echo "Cloudflare mode"
echo "Fetching server IPv6 '$SSH_ALIAS'..."
    IP_ADDRESS=$(server_exec "ip -6 addr show scope global | grep -oP '(?<=inet6 )[0-9a-f:]+' | head -1" 2>/dev/null)

if [ -z "$IP_ADDRESS" ]; then
    echo "Failed to get IPv6 from server '$SSH_ALIAS'"
    exit 1
fi
echo "   Record: AAAA → $IP_ADDRESS"
echo "   Proxy: ON (orange cloud)"
echo ""

# Check configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Missing Cloudflare configuration!"
    echo "   Run first: ./local/setup-cloudflare.sh"
    exit 1
fi

# Load token
API_TOKEN=$(grep "^API_TOKEN=" "$CONFIG_FILE" | cut -d= -f2)

if [ -z "$API_TOKEN" ]; then
    echo "❌ Missing API_TOKEN in configuration!"
    exit 1
fi

# Extract root domain from full subdomain
ROOT_DOMAIN=$(echo "$FULL_DOMAIN" | rev | cut -d. -f1-2 | rev)
SUBDOMAIN=$(echo "$FULL_DOMAIN" | sed "s/\.$ROOT_DOMAIN$//")

if [ "$SUBDOMAIN" = "$ROOT_DOMAIN" ]; then
    SUBDOMAIN="@"
fi

echo "📍 Domain: $ROOT_DOMAIN"
echo "📍 Subdomain: $SUBDOMAIN"
echo ""

# Find Zone ID
ZONE_ID=$(grep "^${ROOT_DOMAIN}=" "$CONFIG_FILE" | cut -d= -f2)

if [ -z "$ZONE_ID" ]; then
    echo "❌ Zone ID not found for domain: $ROOT_DOMAIN"
    echo "   Available domains in configuration:"
    grep -v "^#" "$CONFIG_FILE" | grep -v "API_TOKEN" | grep "=" || echo "   (none)"
    echo ""
    echo "   Run again: ./local/setup-cloudflare.sh"
    exit 1
fi

echo "🔑 Zone ID: $ZONE_ID"
echo ""

# Check if record already exists
echo "Checking existing records..."
EXISTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$RECORD_TYPE&name=$FULL_DOMAIN" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json")

EXISTING_ID=$(echo "$EXISTING" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//g' | sed 's/"//g')

if [ -n "$EXISTING_ID" ]; then
    echo "⚠️  $RECORD_TYPE record for $FULL_DOMAIN already exists!"
    EXISTING_IP=$(echo "$EXISTING" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//g' | sed 's/"//g')
    echo "   Current IP: $EXISTING_IP"

    # If IP is the same - do nothing, success
    if [ "$EXISTING_IP" = "$IP_ADDRESS" ]; then
        echo "✅ DNS already configured correctly!"
        exit 0
    fi

    # Ask only when terminal is interactive
    if [ -t 0 ]; then
        echo ""
        read -p "Update to $IP_ADDRESS? (y/N) " -n 1 -r
        echo ""
    else
        echo "   Non-interactive mode - skipping update"
        exit 0
    fi

    if [[ $REPLY =~ ^[TtYy]$ ]]; then
        UPDATE_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$EXISTING_ID" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$FULL_DOMAIN\",\"content\":\"$IP_ADDRESS\",\"ttl\":3600,\"proxied\":$PROXY}")

        if echo "$UPDATE_RESPONSE" | grep -q '"success":true'; then
            echo "✅ Record updated!"
        else
            echo "❌ Update failed!"
            echo "$UPDATE_RESPONSE"
            exit 1
        fi
    else
        echo "Cancelled."
        exit 0
    fi
else
    echo "Creating $RECORD_TYPE record..."
    CREATE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$FULL_DOMAIN\",\"content\":\"$IP_ADDRESS\",\"ttl\":3600,\"proxied\":$PROXY}")

    if echo "$CREATE_RESPONSE" | grep -q '"success":true'; then
        echo "✅ Record created!"
    else
        echo "❌ Failed to create record!"
        echo "$CREATE_RESPONSE"
        exit 1
    fi
fi

echo ""
echo "🎉 DNS configured: $FULL_DOMAIN → $IP_ADDRESS ($RECORD_TYPE)"

echo "Cloudflare Proxy: ENABLED"
echo ""
echo "Next step - expose via Caddy:"
echo "   ssh $SSH_ALIAS 'sp-expose $FULL_DOMAIN PORT'"

echo ""
echo "⏳ DNS propagation may take up to 5 minutes."
echo ""
