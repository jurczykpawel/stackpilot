#!/bin/bash

# StackPilot - Stripe Setup for Sellf
# Configures Stripe for payment processing
# Author: Paweł (Lazy Engineer)
#
# Usage:
#   ./local/setup-stripe-sellf.sh [domain]
#
# Examples:
#   ./local/setup-stripe-sellf.sh app.example.com
#   ./local/setup-stripe-sellf.sh

set -e

DOMAIN="${1:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
CONFIG_DIR="$HOME/.config/stackpilot/sellf"
CONFIG_FILE="$CONFIG_DIR/stripe.env"

echo ""
echo -e "${BLUE}💳 Stripe Setup for Sellf${NC}"
echo ""

# =============================================================================
# 1. CHECK EXISTING CONFIGURATION
# =============================================================================

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [ -n "$STRIPE_PUBLISHABLE_KEY" ] && [ -n "$STRIPE_SECRET_KEY" ]; then
        echo -e "${GREEN}✅ Found saved Stripe configuration${NC}"
        # Show only key prefix
        PK_PREFIX=$(echo "$STRIPE_PUBLISHABLE_KEY" | cut -c1-12)
        echo "   Publishable Key: ${PK_PREFIX}..."
        echo ""
        read -p "Use existing configuration? [Y/n]: " USE_EXISTING
        if [[ ! "$USE_EXISTING" =~ ^[Nn]$ ]]; then
            echo ""
            echo -e "${GREEN}✅ Using saved configuration${NC}"
            echo ""
            echo "Variables for deploy.sh:"
            echo "   STRIPE_PK='$STRIPE_PUBLISHABLE_KEY'"
            echo "   STRIPE_SK='$STRIPE_SECRET_KEY'"
            if [ -n "$STRIPE_WEBHOOK_SECRET" ]; then
                echo "   STRIPE_WEBHOOK_SECRET='$STRIPE_WEBHOOK_SECRET'"
            fi
            exit 0
        fi
    fi
fi

# =============================================================================
# 2. MODE: TEST VS PRODUCTION
# =============================================================================

echo "Stripe offers two modes:"
echo "   • Test mode - for testing (cards are not charged)"
echo "   • Live mode - production (real payments)"
echo ""
echo "Recommendation: start with Test mode, switch to Live later"
echo ""
read -p "Use test mode? [Y/n]: " USE_TEST_MODE

if [[ "$USE_TEST_MODE" =~ ^[Nn]$ ]]; then
    KEY_PREFIX="live"
    echo ""
    echo -e "${YELLOW}⚠️  You are using production mode - real money!${NC}"
else
    KEY_PREFIX="test"
    echo ""
    echo "✅ Using test mode"
fi

# =============================================================================
# 3. GET API KEYS
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📋 API KEYS"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "1. Open: https://dashboard.stripe.com/apikeys"
if [ "$KEY_PREFIX" = "test" ]; then
    echo "   (make sure you are in Test mode - toggle in the upper right corner)"
fi
echo ""
echo "2. Copy the keys:"
echo "   • Publishable key (starts with pk_${KEY_PREFIX}_...)"
echo "   • Secret key (starts with sk_${KEY_PREFIX}_...)"
echo ""

read -p "Press Enter to open Stripe..." _

if command -v open &>/dev/null; then
    open "https://dashboard.stripe.com/apikeys"
elif command -v xdg-open &>/dev/null; then
    xdg-open "https://dashboard.stripe.com/apikeys"
fi

echo ""
read -p "STRIPE_PUBLISHABLE_KEY (pk_${KEY_PREFIX}_...): " STRIPE_PUBLISHABLE_KEY

if [ -z "$STRIPE_PUBLISHABLE_KEY" ]; then
    echo -e "${RED}❌ Publishable Key is required${NC}"
    exit 1
fi

# Validation
if [[ ! "$STRIPE_PUBLISHABLE_KEY" =~ ^pk_ ]]; then
    echo -e "${RED}❌ Invalid format (should start with pk_)${NC}"
    exit 1
fi

echo ""
read -p "STRIPE_SECRET_KEY (sk_${KEY_PREFIX}_...): " STRIPE_SECRET_KEY

if [ -z "$STRIPE_SECRET_KEY" ]; then
    echo -e "${RED}❌ Secret Key is required${NC}"
    exit 1
fi

# Validation
if [[ ! "$STRIPE_SECRET_KEY" =~ ^sk_ ]]; then
    echo -e "${RED}❌ Invalid format (should start with sk_)${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ API keys obtained${NC}"

# =============================================================================
# 4. WEBHOOK (optional)
# =============================================================================

STRIPE_WEBHOOK_SECRET=""

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📋 WEBHOOK (optional)"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Webhook allows Stripe to notify Sellf about payments."
echo "You can configure it now or later in the Stripe dashboard."
echo ""

if [ -n "$DOMAIN" ]; then
    WEBHOOK_URL="https://$DOMAIN/api/webhooks/stripe"
    echo "Your endpoint: $WEBHOOK_URL"
    echo ""
fi

read -p "Configure webhook now? [y/N]: " SETUP_WEBHOOK

if [[ "$SETUP_WEBHOOK" =~ ^[TtYy]$ ]]; then
    echo ""
    echo "Step by step:"
    echo "   1. Open: https://dashboard.stripe.com/webhooks"
    echo "   2. Click 'Add endpoint'"
    if [ -n "$DOMAIN" ]; then
        echo "   3. Endpoint URL: $WEBHOOK_URL"
    else
        echo "   3. Endpoint URL: https://YOUR_DOMAIN/api/webhooks/stripe"
    fi
    echo "   4. Events to send: select these events:"
    echo "      • checkout.session.completed"
    echo "      • payment_intent.succeeded"
    echo "      • payment_intent.payment_failed"
    echo "   5. Click 'Add endpoint'"
    echo "   6. Click on the created endpoint"
    echo "   7. In the 'Signing secret' section click 'Reveal' and copy"
    echo ""

    read -p "Press Enter to open Stripe Webhooks..." _

    if command -v open &>/dev/null; then
        open "https://dashboard.stripe.com/webhooks"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "https://dashboard.stripe.com/webhooks"
    fi

    echo ""
    read -p "STRIPE_WEBHOOK_SECRET (whsec_..., or Enter to skip): " STRIPE_WEBHOOK_SECRET

    if [ -n "$STRIPE_WEBHOOK_SECRET" ]; then
        if [[ ! "$STRIPE_WEBHOOK_SECRET" =~ ^whsec_ ]]; then
            echo -e "${YELLOW}⚠️  Format looks unusual (should start with whsec_)${NC}"
        else
            echo -e "${GREEN}✅ Webhook Secret saved${NC}"
        fi
    fi
fi

# =============================================================================
# 5. SAVE CONFIGURATION
# =============================================================================

echo ""
echo "💾 Saving configuration..."

mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
# Sellf - Stripe Configuration
# Generated: $(date)
# Mode: $([ "$KEY_PREFIX" = "test" ] && echo "TEST" || echo "LIVE")

STRIPE_PUBLISHABLE_KEY='$STRIPE_PUBLISHABLE_KEY'
STRIPE_SECRET_KEY='$STRIPE_SECRET_KEY'
EOF

if [ -n "$STRIPE_WEBHOOK_SECRET" ]; then
    echo "STRIPE_WEBHOOK_SECRET='$STRIPE_WEBHOOK_SECRET'" >> "$CONFIG_FILE"
fi

chmod 600 "$CONFIG_FILE"
echo -e "${GREEN}✅ Configuration saved in $CONFIG_FILE${NC}"

# =============================================================================
# 6. SUMMARY
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "${GREEN}🎉 Stripe configured!${NC}"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Configuration saved in: $CONFIG_FILE"
echo ""
echo "Usage with deploy.sh:"
echo "   source ~/.config/stackpilot/sellf/stripe.env"
echo "   STRIPE_PK=\"\$STRIPE_PUBLISHABLE_KEY\" STRIPE_SK=\"\$STRIPE_SECRET_KEY\" \\"
echo "   ./local/deploy.sh sellf --ssh=vps --domain=gf.example.com"
echo ""

if [ "$KEY_PREFIX" = "test" ]; then
    echo -e "${YELLOW}📋 Test card numbers:${NC}"
    echo "   ✅ Success: 4242 4242 4242 4242"
    echo "   ❌ Decline: 4000 0000 0000 0002"
    echo "   🔐 3D Secure: 4000 0025 0000 3155"
    echo ""
fi

if [ -z "$STRIPE_WEBHOOK_SECRET" ]; then
    echo -e "${YELLOW}⚠️  Webhook not configured${NC}"
    echo "   After launching Sellf, configure the webhook:"
    echo "   https://dashboard.stripe.com/webhooks"
    if [ -n "$DOMAIN" ]; then
        echo "   Endpoint: https://$DOMAIN/api/webhooks/stripe"
    fi
    echo ""
fi
