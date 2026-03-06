#!/bin/bash

# StackPilot - Sellf Configuration Setup
# Collects and saves all keys needed for automatic Sellf deployment
# Author: Paweł (Lazy Engineer)
#
# After running this script you can run:
#   ./local/deploy.sh sellf --ssh=ALIAS --yes
#
# Usage:
#   ./local/setup-sellf-config.sh [--ssh=ALIAS]

set -e

# Load libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$REPO_ROOT/lib/sellf-setup.sh"

# Parse arguments
SSH_ALIAS=""
DOMAIN=""
DOMAIN_TYPE=""
SUPABASE_PROJECT=""
NO_SUPABASE=false
NO_STRIPE=false
NO_TURNSTILE=false

for arg in "$@"; do
    case "$arg" in
        --ssh=*) SSH_ALIAS="${arg#*=}" ;;
        --domain=*) DOMAIN="${arg#*=}" ;;
        --domain-type=*) DOMAIN_TYPE="${arg#*=}" ;;
        --supabase-project=*) SUPABASE_PROJECT="${arg#*=}" ;;
        --no-supabase) NO_SUPABASE=true ;;
        --no-stripe) NO_STRIPE=true ;;
        --no-turnstile) NO_TURNSTILE=true ;;
        --help|-h)
            cat <<EOF
Usage: ./local/setup-sellf-config.sh [options]

Options:
  --ssh=ALIAS              SSH alias for the server
  --domain=DOMAIN          Domain (e.g. shop.example.com)
  --domain-type=TYPE       Domain type: cloudflare, caddy
  --supabase-project=REF   Supabase project ref (skips interactive selection)
  --no-supabase            Skip Supabase configuration
  --no-stripe              Skip Stripe configuration
  --no-turnstile           Skip Turnstile configuration

Examples:
  # Full interactive configuration
  ./local/setup-sellf-config.sh

  # With domain and SSH
  ./local/setup-sellf-config.sh --ssh=vps --domain=shop.example.com --domain-type=caddy

  # With a specific Supabase project
  ./local/setup-sellf-config.sh --ssh=vps --supabase-project=abcdefghijk --domain=shop.example.com

  # Supabase only (without Stripe and Turnstile)
  ./local/setup-sellf-config.sh --no-stripe --no-turnstile
EOF
            exit 0
            ;;
    esac
done

# Validate domain-type
if [ -n "$DOMAIN_TYPE" ]; then
    case "$DOMAIN_TYPE" in
        cloudflare|caddy) ;;
        *)
            echo -e "${RED}Invalid --domain-type: $DOMAIN_TYPE${NC}"
            echo "   Allowed: cloudflare, caddy"
            exit 1
            ;;
    esac
fi

# Configuration
CONFIG_FILE="$HOME/.config/stackpilot/sellf/deploy-config.env"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "${BLUE}🔧 Sellf - Key Configuration${NC}"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "This script will collect all keys needed for deployment."
echo "Each step is optional - press Enter to skip."
echo ""
echo "After completion you can run the deployment automatically:"
echo -e "   ${BLUE}./local/deploy.sh sellf --ssh=ALIAS --yes${NC}"
echo ""

# =============================================================================
# 1. SSH ALIAS
# =============================================================================

echo "════════════════════════════════════════════════════════════════"
echo "1️⃣  SSH - Target Server"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [ -z "$SSH_ALIAS" ]; then
    echo "Available SSH aliases (from ~/.ssh/config):"
    grep -E "^Host " ~/.ssh/config 2>/dev/null | awk '{print "   • " $2}' | head -10
    echo ""
    read -p "SSH alias [Enter to skip]: " SSH_ALIAS
fi

if [ -n "$SSH_ALIAS" ]; then
    echo -e "${GREEN}   ✅ SSH: $SSH_ALIAS${NC}"
else
    echo -e "${YELLOW}   ⏭️  Skipped - you'll provide it during deployment${NC}"
fi

# =============================================================================
# 2. SUPABASE
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "2️⃣  Supabase - Database and Auth"
echo "════════════════════════════════════════════════════════════════"
echo ""

SUPABASE_CONFIGURED=false

if [ "$NO_SUPABASE" = true ]; then
    echo -e "${YELLOW}   ⏭️  Skipped (--no-supabase)${NC}"
elif [ -n "$SUPABASE_PROJECT" ]; then
    # Project ref provided via CLI - fetch keys automatically
    echo "   Project: $SUPABASE_PROJECT"

    # Make sure we have a token
    if ! check_saved_supabase_token; then
        if ! supabase_manual_token_flow; then
            echo -e "${RED}   ❌ Missing Supabase token${NC}"
        fi
        if [ -n "$SUPABASE_TOKEN" ]; then
            save_supabase_token "$SUPABASE_TOKEN"
        fi
    fi

    if [ -n "$SUPABASE_TOKEN" ]; then
        if fetch_supabase_keys_by_ref "$SUPABASE_PROJECT"; then
            SUPABASE_CONFIGURED=true
            echo -e "${GREEN}   ✅ Supabase configured${NC}"
        fi
    fi
else
    read -p "Configure Supabase now? [Y/n]: " SETUP_SUPABASE
    if [[ ! "$SETUP_SUPABASE" =~ ^[Nn]$ ]]; then
        # Token
        if ! check_saved_supabase_token; then
            if ! supabase_login_flow; then
                echo -e "${YELLOW}   ⚠️  Login failed, try manually${NC}"
                supabase_manual_token_flow
            fi
            if [ -n "$SUPABASE_TOKEN" ]; then
                save_supabase_token "$SUPABASE_TOKEN"
            fi
        fi

        # Project selection
        if [ -n "$SUPABASE_TOKEN" ]; then
            if select_supabase_project; then
                SUPABASE_CONFIGURED=true
                echo -e "${GREEN}   ✅ Supabase configured${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}   ⏭️  Skipped${NC}"
    fi
fi

# =============================================================================
# 3. STRIPE
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "3️⃣  Stripe - Payments"
echo "════════════════════════════════════════════════════════════════"
echo ""

STRIPE_PK="${STRIPE_PK:-}"
STRIPE_SK="${STRIPE_SK:-}"
STRIPE_WEBHOOK_SECRET="${STRIPE_WEBHOOK_SECRET:-}"

if [ "$NO_STRIPE" = true ]; then
    echo -e "${YELLOW}   ⏭️  Skipped (--no-stripe)${NC}"
else
    read -p "Configure Stripe now? [Y/n]: " SETUP_STRIPE
    if [[ ! "$SETUP_STRIPE" =~ ^[Nn]$ ]]; then
        echo ""
        echo "   Open: https://dashboard.stripe.com/apikeys"
        echo ""
        read -p "STRIPE_PUBLISHABLE_KEY (pk_...): " STRIPE_PK

        if [ -n "$STRIPE_PK" ]; then
            read -p "STRIPE_SECRET_KEY (sk_...): " STRIPE_SK
            read -p "STRIPE_WEBHOOK_SECRET (whsec_..., optional): " STRIPE_WEBHOOK_SECRET
            echo -e "${GREEN}   ✅ Stripe configured${NC}"
        else
            echo -e "${YELLOW}   ⏭️  Skipped${NC}"
        fi
    else
        echo -e "${YELLOW}   ⏭️  Skipped - you can configure it in the Sellf panel${NC}"
    fi
fi

# =============================================================================
# 4. CLOUDFLARE TURNSTILE
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "4️⃣  Cloudflare Turnstile - CAPTCHA (optional)"
echo "════════════════════════════════════════════════════════════════"
echo ""

TURNSTILE_SITE_KEY="${TURNSTILE_SITE_KEY:-}"
TURNSTILE_SECRET_KEY="${TURNSTILE_SECRET_KEY:-}"

if [ "$NO_TURNSTILE" = true ]; then
    echo -e "${YELLOW}   ⏭️  Skipped (--no-turnstile)${NC}"
elif [[ "$SETUP_TURNSTILE" =~ ^[TtYy]$ ]] || { read -p "Configure Turnstile now? [y/N]: " SETUP_TURNSTILE; [[ "$SETUP_TURNSTILE" =~ ^[TtYy]$ ]]; }; then
    echo ""
    echo "   You can configure Turnstile in two ways:"
    echo "   a) Automatically via API (requires Cloudflare token)"
    echo "   b) Manually - copy keys from the dashboard"
    echo ""
    read -p "Use Cloudflare API? [Y/n]: " USE_CF_API

    if [[ ! "$USE_CF_API" =~ ^[Nn]$ ]]; then
        # Check if we have a Cloudflare token
        CF_TOKEN_FILE="$HOME/.config/cloudflare/api_token"
        if [ -f "$CF_TOKEN_FILE" ]; then
            echo "   🔑 Found saved Cloudflare token"
        else
            echo ""
            echo "   You need an API Token with permissions:"
            echo "   • Account > Turnstile > Edit"
            echo ""
            echo "   Open: https://dash.cloudflare.com/profile/api-tokens"
            echo ""
            read -p "Cloudflare API Token: " CF_API_TOKEN

            if [ -n "$CF_API_TOKEN" ]; then
                mkdir -p "$(dirname "$CF_TOKEN_FILE")"
                echo "$CF_API_TOKEN" > "$CF_TOKEN_FILE"
                chmod 600 "$CF_TOKEN_FILE"
            fi
        fi

        echo -e "${YELLOW}   ℹ️  Turnstile will be configured during deployment${NC}"
        echo "   (requires knowing the domain)"
    else
        echo ""
        echo "   Open: https://dash.cloudflare.com/?to=/:account/turnstile"
        echo ""
        read -p "TURNSTILE_SITE_KEY: " TURNSTILE_SITE_KEY

        if [ -n "$TURNSTILE_SITE_KEY" ]; then
            read -p "TURNSTILE_SECRET_KEY: " TURNSTILE_SECRET_KEY
            echo -e "${GREEN}   ✅ Turnstile configured${NC}"
        else
            echo -e "${YELLOW}   ⏭️  Skipped${NC}"
        fi
    fi
else
    echo -e "${YELLOW}   ⏭️  Skipped${NC}"
fi

# =============================================================================
# 5. DOMAIN (optional)
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "5️⃣  Domain (optional)"
echo "════════════════════════════════════════════════════════════════"
echo ""

# If DOMAIN was provided via CLI, skip questions
if [ -n "$DOMAIN" ]; then
    echo -e "${GREEN}   Domain: $DOMAIN ($DOMAIN_TYPE)${NC}"
else
    echo "   1) Custom domain (e.g. shop.example.com)"
    echo "   2) Skip - I'll choose during deployment"
    echo ""
    read -p "Choose [1-2, default 2]: " DOMAIN_CHOICE

    case "$DOMAIN_CHOICE" in
        1)
            read -p "Enter domain (e.g. app.example.com): " DOMAIN
            if [ -n "$DOMAIN" ]; then
                echo "   Domain type:"
                echo "   a) Cloudflare (automated DNS)"
                echo "   b) Caddy auto-HTTPS (manual DNS A record)"
                read -p "Choose [a/b]: " DTYPE
                if [[ "$DTYPE" =~ ^[Aa]$ ]]; then
                    DOMAIN_TYPE="cloudflare"
                else
                    DOMAIN_TYPE="caddy"
                fi
                echo -e "${GREEN}   Domain: $DOMAIN ($DOMAIN_TYPE)${NC}"
            fi
            ;;
        *)
            echo -e "${YELLOW}   Skipped - you'll choose during deployment${NC}"
            ;;
    esac
fi

# =============================================================================
# 6. SAVE CONFIGURATION
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "💾 Saving configuration..."
echo "════════════════════════════════════════════════════════════════"
echo ""

mkdir -p "$(dirname "$CONFIG_FILE")"

cat > "$CONFIG_FILE" << EOF
# Sellf Deploy Configuration
# Generated by setup-sellf-config.sh
# Date: $(date)

# SSH
SSH_ALIAS="$SSH_ALIAS"

# Supabase (keys in separate files for security)
SUPABASE_CONFIGURED=$SUPABASE_CONFIGURED
EOF

# Add Supabase if configured
if [ "$SUPABASE_CONFIGURED" = true ]; then
    cat >> "$CONFIG_FILE" << EOF
SUPABASE_URL="$SUPABASE_URL"
PROJECT_REF="$PROJECT_REF"
SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"
SUPABASE_SERVICE_KEY="$SUPABASE_SERVICE_KEY"
EOF
fi

# Add Stripe if provided
if [ -n "$STRIPE_PK" ]; then
    cat >> "$CONFIG_FILE" << EOF

# Stripe
STRIPE_PK="$STRIPE_PK"
STRIPE_SK="$STRIPE_SK"
STRIPE_WEBHOOK_SECRET="$STRIPE_WEBHOOK_SECRET"
EOF
fi

# Add Turnstile if provided manually
if [ -n "$TURNSTILE_SITE_KEY" ]; then
    cat >> "$CONFIG_FILE" << EOF

# Cloudflare Turnstile
CLOUDFLARE_TURNSTILE_SITE_KEY="$TURNSTILE_SITE_KEY"
CLOUDFLARE_TURNSTILE_SECRET_KEY="$TURNSTILE_SECRET_KEY"
EOF
fi

# Add domain if provided
if [ -n "$DOMAIN" ]; then
    cat >> "$CONFIG_FILE" << EOF

# Domain
DOMAIN="$DOMAIN"
DOMAIN_TYPE="$DOMAIN_TYPE"
EOF
fi

chmod 600 "$CONFIG_FILE"

echo -e "${GREEN}✅ Configuration saved to:${NC}"
echo "   $CONFIG_FILE"
echo ""

# =============================================================================
# 7. SUMMARY
# =============================================================================

echo "════════════════════════════════════════════════════════════════"
echo "📋 Summary"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Configured:"
[ -n "$SSH_ALIAS" ] && echo -e "   ${GREEN}✅${NC} SSH: $SSH_ALIAS"
[ "$SUPABASE_CONFIGURED" = true ] && echo -e "   ${GREEN}✅${NC} Supabase: $PROJECT_REF"
[ -n "$STRIPE_PK" ] && echo -e "   ${GREEN}✅${NC} Stripe"
[ -n "$TURNSTILE_SITE_KEY" ] && echo -e "   ${GREEN}✅${NC} Turnstile"
[ -n "$DOMAIN" ] && echo -e "   ${GREEN}✅${NC} Domain: $DOMAIN"

echo ""
echo "Skipped (can be configured later):"
[ -z "$SSH_ALIAS" ] && echo -e "   ${YELLOW}⏭️${NC}  SSH"
[ "$SUPABASE_CONFIGURED" != true ] && echo -e "   ${YELLOW}⏭️${NC}  Supabase"
[ -z "$STRIPE_PK" ] && echo -e "   ${YELLOW}⏭️${NC}  Stripe (configure in the panel)"
[ -z "$TURNSTILE_SITE_KEY" ] && echo -e "   ${YELLOW}⏭️${NC}  Turnstile"
[ -z "$DOMAIN" ] && echo -e "   ${YELLOW}⏭️${NC}  Domain"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🚀 Next step - deployment"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [ -n "$SSH_ALIAS" ] && [ "$SUPABASE_CONFIGURED" = true ]; then
    echo "You can now run the deployment automatically:"
    echo ""
    echo -e "   ${BLUE}./local/deploy.sh sellf --ssh=$SSH_ALIAS --yes${NC}"
else
    echo "Run deployment (it will ask about missing details):"
    echo ""
    if [ -n "$SSH_ALIAS" ]; then
        echo -e "   ${BLUE}./local/deploy.sh sellf --ssh=$SSH_ALIAS${NC}"
    else
        echo -e "   ${BLUE}./local/deploy.sh sellf --ssh=YOUR_ALIAS${NC}"
    fi
fi
echo ""
