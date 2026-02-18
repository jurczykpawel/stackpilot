#!/bin/bash

# Mikrus Toolbox - Stripe Setup for GateFlow
# Konfiguruje Stripe do obsługi płatności
# Author: Paweł (Lazy Engineer)
#
# Użycie:
#   ./local/setup-stripe-gateflow.sh [domena]
#
# Przykłady:
#   ./local/setup-stripe-gateflow.sh app.example.com
#   ./local/setup-stripe-gateflow.sh

set -e

DOMAIN="${1:-}"

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Konfiguracja
CONFIG_DIR="$HOME/.config/gateflow"
CONFIG_FILE="$CONFIG_DIR/stripe.env"

echo ""
echo -e "${BLUE}💳 Stripe Setup for GateFlow${NC}"
echo ""

# =============================================================================
# 1. SPRAWDŹ ISTNIEJĄCĄ KONFIGURACJĘ
# =============================================================================

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [ -n "$STRIPE_PUBLISHABLE_KEY" ] && [ -n "$STRIPE_SECRET_KEY" ]; then
        echo -e "${GREEN}✅ Znaleziono zapisaną konfigurację Stripe${NC}"
        # Pokazuj tylko prefix klucza
        PK_PREFIX=$(echo "$STRIPE_PUBLISHABLE_KEY" | cut -c1-12)
        echo "   Publishable Key: ${PK_PREFIX}..."
        echo ""
        read -p "Użyć istniejącej konfiguracji? [T/n]: " USE_EXISTING
        if [[ ! "$USE_EXISTING" =~ ^[Nn]$ ]]; then
            echo ""
            echo -e "${GREEN}✅ Używam zapisanej konfiguracji${NC}"
            echo ""
            echo "Zmienne do użycia w deploy.sh:"
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
# 2. TRYB: TEST VS PRODUCTION
# =============================================================================

echo "Stripe oferuje dwa tryby:"
echo "   • Test mode - do testowania (karty nie są obciążane)"
echo "   • Live mode - produkcja (prawdziwe płatności)"
echo ""
echo "Zalecenie: zacznij od Test mode, później przełącz na Live"
echo ""
read -p "Użyć trybu testowego? [T/n]: " USE_TEST_MODE

if [[ "$USE_TEST_MODE" =~ ^[Nn]$ ]]; then
    KEY_PREFIX="live"
    echo ""
    echo -e "${YELLOW}⚠️  Używasz trybu produkcyjnego - prawdziwe pieniądze!${NC}"
else
    KEY_PREFIX="test"
    echo ""
    echo "✅ Używam trybu testowego"
fi

# =============================================================================
# 3. POBIERZ KLUCZE API
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📋 KLUCZE API"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "1. Otwórz: https://dashboard.stripe.com/apikeys"
if [ "$KEY_PREFIX" = "test" ]; then
    echo "   (upewnij się że jesteś w Test mode - przełącznik w prawym górnym rogu)"
fi
echo ""
echo "2. Skopiuj klucze:"
echo "   • Publishable key (zaczyna się od pk_${KEY_PREFIX}_...)"
echo "   • Secret key (zaczyna się od sk_${KEY_PREFIX}_...)"
echo ""

read -p "Naciśnij Enter aby otworzyć Stripe..." _

if command -v open &>/dev/null; then
    open "https://dashboard.stripe.com/apikeys"
elif command -v xdg-open &>/dev/null; then
    xdg-open "https://dashboard.stripe.com/apikeys"
fi

echo ""
read -p "STRIPE_PUBLISHABLE_KEY (pk_${KEY_PREFIX}_...): " STRIPE_PUBLISHABLE_KEY

if [ -z "$STRIPE_PUBLISHABLE_KEY" ]; then
    echo -e "${RED}❌ Publishable Key jest wymagany${NC}"
    exit 1
fi

# Walidacja
if [[ ! "$STRIPE_PUBLISHABLE_KEY" =~ ^pk_ ]]; then
    echo -e "${RED}❌ Nieprawidłowy format (powinien zaczynać się od pk_)${NC}"
    exit 1
fi

echo ""
read -p "STRIPE_SECRET_KEY (sk_${KEY_PREFIX}_...): " STRIPE_SECRET_KEY

if [ -z "$STRIPE_SECRET_KEY" ]; then
    echo -e "${RED}❌ Secret Key jest wymagany${NC}"
    exit 1
fi

# Walidacja
if [[ ! "$STRIPE_SECRET_KEY" =~ ^sk_ ]]; then
    echo -e "${RED}❌ Nieprawidłowy format (powinien zaczynać się od sk_)${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ Klucze API pobrane${NC}"

# =============================================================================
# 4. WEBHOOK (opcjonalne)
# =============================================================================

STRIPE_WEBHOOK_SECRET=""

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📋 WEBHOOK (opcjonalne)"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Webhook pozwala Stripe powiadamiać GateFlow o płatnościach."
echo "Możesz skonfigurować go teraz lub później w panelu Stripe."
echo ""

if [ -n "$DOMAIN" ]; then
    WEBHOOK_URL="https://$DOMAIN/api/webhooks/stripe"
    echo "Twój endpoint: $WEBHOOK_URL"
    echo ""
fi

read -p "Skonfigurować webhook teraz? [t/N]: " SETUP_WEBHOOK

if [[ "$SETUP_WEBHOOK" =~ ^[TtYy]$ ]]; then
    echo ""
    echo "Krok po kroku:"
    echo "   1. Otwórz: https://dashboard.stripe.com/webhooks"
    echo "   2. Kliknij 'Add endpoint'"
    if [ -n "$DOMAIN" ]; then
        echo "   3. Endpoint URL: $WEBHOOK_URL"
    else
        echo "   3. Endpoint URL: https://TWOJA_DOMENA/api/webhooks/stripe"
    fi
    echo "   4. Events to send: wybierz te wydarzenia:"
    echo "      • checkout.session.completed"
    echo "      • payment_intent.succeeded"
    echo "      • payment_intent.payment_failed"
    echo "   5. Kliknij 'Add endpoint'"
    echo "   6. Kliknij na utworzony endpoint"
    echo "   7. W sekcji 'Signing secret' kliknij 'Reveal' i skopiuj"
    echo ""

    read -p "Naciśnij Enter aby otworzyć Stripe Webhooks..." _

    if command -v open &>/dev/null; then
        open "https://dashboard.stripe.com/webhooks"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "https://dashboard.stripe.com/webhooks"
    fi

    echo ""
    read -p "STRIPE_WEBHOOK_SECRET (whsec_..., lub Enter aby pominąć): " STRIPE_WEBHOOK_SECRET

    if [ -n "$STRIPE_WEBHOOK_SECRET" ]; then
        if [[ ! "$STRIPE_WEBHOOK_SECRET" =~ ^whsec_ ]]; then
            echo -e "${YELLOW}⚠️  Format wygląda nietypowo (powinien zaczynać się od whsec_)${NC}"
        else
            echo -e "${GREEN}✅ Webhook Secret zapisany${NC}"
        fi
    fi
fi

# =============================================================================
# 5. ZAPISZ KONFIGURACJĘ
# =============================================================================

echo ""
echo "💾 Zapisuję konfigurację..."

mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
# GateFlow - Stripe Configuration
# Wygenerowano: $(date)
# Tryb: $([ "$KEY_PREFIX" = "test" ] && echo "TEST" || echo "LIVE")

STRIPE_PUBLISHABLE_KEY='$STRIPE_PUBLISHABLE_KEY'
STRIPE_SECRET_KEY='$STRIPE_SECRET_KEY'
EOF

if [ -n "$STRIPE_WEBHOOK_SECRET" ]; then
    echo "STRIPE_WEBHOOK_SECRET='$STRIPE_WEBHOOK_SECRET'" >> "$CONFIG_FILE"
fi

chmod 600 "$CONFIG_FILE"
echo -e "${GREEN}✅ Konfiguracja zapisana w $CONFIG_FILE${NC}"

# =============================================================================
# 6. PODSUMOWANIE
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "${GREEN}🎉 Stripe skonfigurowany!${NC}"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Konfiguracja zapisana w: $CONFIG_FILE"
echo ""
echo "Użycie z deploy.sh:"
echo "   source ~/.config/gateflow/stripe.env"
echo "   STRIPE_PK=\"\$STRIPE_PUBLISHABLE_KEY\" STRIPE_SK=\"\$STRIPE_SECRET_KEY\" \\"
echo "   ./local/deploy.sh gateflow --ssh=mikrus --domain=gf.example.com"
echo ""

if [ "$KEY_PREFIX" = "test" ]; then
    echo -e "${YELLOW}📋 Testowe numery kart:${NC}"
    echo "   ✅ Sukces: 4242 4242 4242 4242"
    echo "   ❌ Odmowa: 4000 0000 0000 0002"
    echo "   🔐 3D Secure: 4000 0025 0000 3155"
    echo ""
fi

if [ -z "$STRIPE_WEBHOOK_SECRET" ]; then
    echo -e "${YELLOW}⚠️  Webhook nie skonfigurowany${NC}"
    echo "   Po uruchomieniu GateFlow, skonfiguruj webhook:"
    echo "   https://dashboard.stripe.com/webhooks"
    if [ -n "$DOMAIN" ]; then
        echo "   Endpoint: https://$DOMAIN/api/webhooks/stripe"
    fi
    echo ""
fi
