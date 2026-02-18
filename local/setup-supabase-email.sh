#!/bin/bash

# StackPilot - Supabase SMTP Setup
# Configures SMTP for sending emails in GateFlow
# Author: Paweł (Lazy Engineer)
#
# NOTE: Email templates are configured automatically by deploy.sh
# This script is only for configuring SMTP (custom email server)
#
# Uses Supabase Management API
#
# Usage:
#   ./local/setup-supabase-email.sh

set -e

# Load Supabase library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$REPO_ROOT/lib/gateflow-setup.sh"

echo ""
echo -e "${BLUE}📮 SMTP Configuration for Supabase${NC}"
echo ""

# =============================================================================
# 1. SUPABASE TOKEN
# =============================================================================

if ! check_saved_supabase_token; then
    if ! supabase_manual_token_flow; then
        echo -e "${RED}❌ Failed to obtain token${NC}"
        exit 1
    fi
    save_supabase_token "$SUPABASE_TOKEN"
fi

# =============================================================================
# 2. SELECT SUPABASE PROJECT
# =============================================================================

if ! select_supabase_project; then
    echo -e "${RED}❌ Failed to select project${NC}"
    exit 1
fi

# Use SUPABASE_TOKEN instead of SUPABASE_ACCESS_TOKEN (compatibility with rest of script)
SUPABASE_ACCESS_TOKEN="$SUPABASE_TOKEN"

# =============================================================================
# 3. SMTP CONFIGURATION
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📮 SMTP CONFIGURATION"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Popular options:"
echo "   • Gmail: smtp.gmail.com (requires App Password)"
echo "   • Resend: smtp.resend.com"
echo "   • SendGrid: smtp.sendgrid.net"
echo ""

read -p "SMTP Host: " SMTP_HOST

if [ -z "$SMTP_HOST" ]; then
    echo -e "${YELLOW}⚠️  Cancelled${NC}"
    exit 0
fi

# Default port
DEFAULT_PORT="587"
if [[ "$SMTP_HOST" == *"resend"* ]]; then
    DEFAULT_PORT="465"
fi

read -p "SMTP Port [$DEFAULT_PORT]: " SMTP_PORT
SMTP_PORT="${SMTP_PORT:-$DEFAULT_PORT}"

read -p "SMTP Username (email): " SMTP_USER
read -sp "SMTP Password: " SMTP_PASS
echo ""

read -p "Sender email address (e.g. noreply@yourdomain.com): " SMTP_SENDER_EMAIL
read -p "Sender name [GateFlow]: " SMTP_SENDER_NAME
SMTP_SENDER_NAME="${SMTP_SENDER_NAME:-GateFlow}"

# =============================================================================
# 4. SAVE CONFIGURATION
# =============================================================================

echo ""
echo "🚀 Saving SMTP configuration in Supabase..."

# Build JSON payload
CONFIG_JSON=$(jq -n \
    --arg host "$SMTP_HOST" \
    --arg port "$SMTP_PORT" \
    --arg user "$SMTP_USER" \
    --arg pass "$SMTP_PASS" \
    --arg email "$SMTP_SENDER_EMAIL" \
    --arg name "$SMTP_SENDER_NAME" \
    '{
        smtp_host: $host,
        smtp_port: $port,
        smtp_user: $user,
        smtp_pass: $pass,
        smtp_admin_email: $email,
        smtp_sender_name: $name
    }')

# Send to API
RESPONSE=$(curl -s -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$CONFIG_JSON")

if echo "$RESPONSE" | grep -q '"error"'; then
    ERROR=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
    echo -e "${RED}❌ Error: $ERROR${NC}"
    exit 1
fi

# =============================================================================
# 5. SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}✅ SMTP configured!${NC}"
echo ""
echo "📮 Settings:"
echo "   Host: $SMTP_HOST:$SMTP_PORT"
echo "   Sender: $SMTP_SENDER_NAME <$SMTP_SENDER_EMAIL>"
echo ""

if [[ "$SMTP_HOST" == *"gmail"* ]]; then
    echo -e "${YELLOW}💡 For Gmail use an App Password:${NC}"
    echo "   https://myaccount.google.com/apppasswords"
    echo ""
fi

echo "Emails will be sent through your SMTP server instead of the default Supabase."
echo ""
