#!/bin/bash

# StackPilot - Sellf on Netlify (+ Supabase Cloud + Stripe test mode)
# Author: Paweł (Lazy Engineer)
#
# Mirror of install-vercel.sh but targeting Netlify instead of Vercel.
# Provisions Sellf end-to-end in ~5–7 minutes from a clean slate.
#
# Prerequisites:
#   netlify   — npm i -g netlify-cli  — logged in via NETLIFY_AUTH_TOKEN or `netlify login`
#   supabase  — npm i -g supabase     — logged in via `supabase login`
#   stripe    — brew install stripe/stripe-cli/stripe — logged in via `stripe login`
#   openssl, jq, curl — system
#
# Environment variables (all optional; prompted if absent):
#   NETLIFY_AUTH_TOKEN — Netlify PAT (preferred); falls back to `netlify login` cache
#   NETLIFY_ACCOUNT_SLUG — Netlify team slug (auto-detected from first team if absent)
#   PROJECT_NAME       — both Netlify site name and Supabase project name
#                        Default: sellf-<unix-ts>
#   SUPABASE_ORG_ID    — Default: first org in `supabase orgs list`
#   SUPABASE_REGION    — Default: eu-central-1
#   STRIPE_SK / STRIPE_PK — sk_test_… / pk_test_… (prompts if absent)
#   REPO_PATH          — Sellf repo checkout path. Default: pwd
#
# Output:
#   Live URL printed at the end + path to .env.deploy.<project> with creds.

set -e

# ---------- Argument parsing ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --project-name)    PROJECT_NAME="$2"; shift 2 ;;
        --account-slug)    NETLIFY_ACCOUNT_SLUG="$2"; shift 2 ;;
        --supabase-org)    SUPABASE_ORG_ID="$2"; shift 2 ;;
        --supabase-region) SUPABASE_REGION="$2"; shift 2 ;;
        --stripe-sk)       STRIPE_SK="$2"; shift 2 ;;
        --stripe-pk)       STRIPE_PK="$2"; shift 2 ;;
        --repo-path)       REPO_PATH="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set -e/p' "$0" | sed 's/^# \?//; /^set -e/d'
            exit 0
            ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

PROJECT_NAME="${PROJECT_NAME:-sellf-$(date +%s)}"
SUPABASE_REGION="${SUPABASE_REGION:-eu-central-1}"
REPO_PATH="${REPO_PATH:-$(pwd)}"

# ---------- Pre-flight ----------
echo "--- 🚀 Sellf → Netlify + Supabase Cloud + Stripe ---"
echo ""
echo "  Project name:    $PROJECT_NAME"
echo "  Supabase region: $SUPABASE_REGION"
echo "  Repo path:       $REPO_PATH"
echo ""

for cmd in netlify supabase stripe openssl jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Missing required CLI: $cmd"
        exit 1
    fi
done

# Sellf repo sanity check
if [ ! -f "$REPO_PATH/admin-panel/package.json" ] || [ ! -d "$REPO_PATH/supabase/migrations" ] || [ ! -f "$REPO_PATH/netlify.toml" ]; then
    echo "❌ $REPO_PATH does not look like a Sellf checkout (need admin-panel/, supabase/migrations/, netlify.toml)."
    exit 1
fi

# CLI auth — `netlify status` always exits 0 even when not logged in.
# Use a real API call to check.
netlify api listAccountsForUser >/dev/null 2>&1 || { echo "❌ netlify: not logged in. Set NETLIFY_AUTH_TOKEN or run: netlify login"; exit 1; }
supabase projects list >/dev/null 2>&1 || { echo "❌ supabase: not logged in. Run: supabase login"; exit 1; }
stripe config --list 2>/dev/null | grep -q "test_mode_api_key" || { echo "❌ stripe: not logged in. Run: stripe login"; exit 1; }

# Stripe keys
if [ -z "$STRIPE_SK" ] || [ -z "$STRIPE_PK" ]; then
    echo ""
    echo "Stripe test keys needed (https://dashboard.stripe.com/test/apikeys):"
    [ -z "$STRIPE_SK" ] && read -r -p "  STRIPE_SK (sk_test_…): " STRIPE_SK
    [ -z "$STRIPE_PK" ] && read -r -p "  STRIPE_PK (pk_test_…): " STRIPE_PK
fi
case "$STRIPE_SK" in sk_test_*) ;; *) echo "❌ STRIPE_SK must start with sk_test_"; exit 1 ;; esac
case "$STRIPE_PK" in pk_test_*) ;; *) echo "❌ STRIPE_PK must start with pk_test_"; exit 1 ;; esac

# Supabase org
if [ -z "$SUPABASE_ORG_ID" ]; then
    SUPABASE_ORG_ID=$(supabase orgs list 2>/dev/null | awk -F'|' '/[a-z]{20}/ {gsub(/^ +| +$/,"",$1); print $1; exit}')
    [ -z "$SUPABASE_ORG_ID" ] && { echo "❌ Could not auto-detect Supabase org. Pass --supabase-org <id>."; exit 1; }
    echo "  Supabase org:    $SUPABASE_ORG_ID (auto-detected)"
fi

# Netlify account
if [ -z "$NETLIFY_ACCOUNT_SLUG" ]; then
    NETLIFY_ACCOUNT_SLUG=$(netlify api listAccountsForUser 2>/dev/null | jq -r '.[0].slug // empty')
    [ -z "$NETLIFY_ACCOUNT_SLUG" ] && { echo "❌ Could not auto-detect Netlify account. Pass --account-slug <slug>."; exit 1; }
    echo "  Netlify team:    $NETLIFY_ACCOUNT_SLUG (auto-detected)"
fi
echo ""

# ---------- Step 1: Generate secrets ----------
echo "[1/9] Generating secrets…"
CHECKOUT_BINDING_SECRET=$(openssl rand -base64 32)
APP_ENCRYPTION_KEY=$(openssl rand -base64 32)
LOGINWALL_SECRET=$(openssl rand -hex 32)
DB_PASS=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)

# ---------- Step 2: Create Supabase project ----------
echo "[2/9] Creating Supabase project '$PROJECT_NAME' in $SUPABASE_REGION…"
supabase projects create "$PROJECT_NAME" \
    --org-id "$SUPABASE_ORG_ID" \
    --db-password "$DB_PASS" \
    --region "$SUPABASE_REGION" > /dev/null
PROJECT_REF=$(supabase projects list 2>/dev/null \
    | awk -F'|' -v n="$PROJECT_NAME" '$0 ~ n {gsub(/^ +| +$/,"",$3); print $3; exit}')
[ -z "$PROJECT_REF" ] && { echo "❌ Failed to read project ref after create."; exit 1; }
echo "      ref: $PROJECT_REF"

# ---------- Step 3: Wait for provisioning + fetch keys ----------
echo "[3/9] Waiting for Supabase provisioning + fetching keys…"
SB_URL="https://${PROJECT_REF}.supabase.co"
for i in 1 2 3 4 5 6; do
    KEYS=$(supabase projects api-keys --project-ref "$PROJECT_REF" 2>&1)
    if echo "$KEYS" | grep -q "anon"; then break; fi
    [ "$i" = "6" ] && { echo "❌ Supabase provisioning timed out."; exit 1; }
    sleep 20
done
SB_ANON=$(echo "$KEYS" | grep -E '^\s+anon\s+\|' | sed 's/.*| //' | tr -d ' ')
SB_SVC=$(echo "$KEYS"  | grep -E '^\s+service_role\s+\|' | sed 's/.*| //' | tr -d ' ')
[ -z "$SB_ANON" ] || [ -z "$SB_SVC" ] && { echo "❌ Could not parse Supabase keys."; exit 1; }

# ---------- Step 4: Create Netlify site ----------
echo "[4/9] Creating Netlify site '$PROJECT_NAME'…"
cd "$REPO_PATH"
# Remove any stale .netlify link in admin-panel or root
rm -rf .netlify admin-panel/.netlify
SITE_INFO=$(netlify sites:create --name "$PROJECT_NAME" --account-slug "$NETLIFY_ACCOUNT_SLUG" 2>&1 \
    | sed $'s/\033\\[[0-9;]*m//g')   # strip ANSI codes
SITE_ID=$(echo "$SITE_INFO" | grep -oE 'Project ID: [a-f0-9-]{36}' | awk '{print $NF}')
SITE_URL=$(echo "$SITE_INFO" | grep -oE 'URL: +https://[^[:space:]]+' | tail -1 | awk '{print $NF}')
[ -z "$SITE_ID" ] && { echo "❌ Could not parse Netlify site id."; echo "$SITE_INFO"; exit 1; }
[ -z "$SITE_URL" ] && SITE_URL="https://${PROJECT_NAME}.netlify.app"
echo "      site_id: $SITE_ID"
echo "      url:     $SITE_URL"

# Link the worktree (root, where netlify.toml lives — base=admin-panel inside)
netlify link --id "$SITE_ID" > /dev/null

# ---------- Step 5: Set env vars ----------
echo "[5/9] Setting 11 environment variables…"
# Netlify uses env:set; values are visible by default — they're encrypted at rest.
# Don't use --secret in non-production contexts; --secret requires --context production
# and we're setting all-contexts (no flag).
set_env() {
    netlify env:set "$1" "$2" > /dev/null
}

set_env SUPABASE_URL                  "$SB_URL"
set_env SUPABASE_ANON_KEY             "$SB_ANON"
set_env SUPABASE_SERVICE_ROLE_KEY     "$SB_SVC"
set_env STRIPE_SECRET_KEY             "$STRIPE_SK"
set_env STRIPE_PUBLISHABLE_KEY        "$STRIPE_PK"
set_env STRIPE_WEBHOOK_SECRET         "whsec_PLACEHOLDER_for_first_deploy_replace_after_xxxxx"
set_env SITE_URL                      "$SITE_URL"
set_env CHECKOUT_BINDING_SECRET       "$CHECKOUT_BINDING_SECRET"
set_env TRUSTED_PROXY                 "true"
set_env APP_ENCRYPTION_KEY            "$APP_ENCRYPTION_KEY"
set_env LOGINWALL_SECRET              "$LOGINWALL_SECRET"

# ---------- Step 6: First deploy ----------
echo "[6/9] Building + deploying to Netlify (this takes ~1 minute)…"
DEPLOY_OUT=$(netlify deploy --build --prod 2>&1)
echo "$DEPLOY_OUT" | grep -E "Production URL|Build completed" | head -3 | sed 's/^/      /'

# ---------- Step 7: Apply Supabase migrations ----------
echo "[7/9] Applying database migrations…"
supabase link --project-ref "$PROJECT_REF" --password "$DB_PASS" > /dev/null 2>&1
supabase db push --password "$DB_PASS" --yes > /dev/null

# ---------- Step 8: Create Stripe webhook + swap secret ----------
echo "[8/9] Creating Stripe webhook + replacing placeholder…"
WH=$(stripe webhook_endpoints create \
    --url="${SITE_URL}/api/webhooks/stripe" \
    --enabled-events="checkout.session.completed" \
    --enabled-events="checkout.session.async_payment_succeeded" \
    --enabled-events="checkout.session.async_payment_failed" \
    --enabled-events="customer.subscription.created" \
    --enabled-events="customer.subscription.updated" \
    --enabled-events="customer.subscription.deleted" \
    --enabled-events="customer.subscription.trial_will_end" \
    --enabled-events="invoice.paid" --enabled-events="invoice.payment_failed" \
    --enabled-events="payment_intent.succeeded" --enabled-events="payment_intent.payment_failed" \
    --enabled-events="charge.refunded" 2>/dev/null)
WH_ID=$(echo "$WH" | jq -r .id)
WH_SECRET=$(echo "$WH" | jq -r .secret)

set_env STRIPE_WEBHOOK_SECRET "$WH_SECRET"
netlify deploy --build --prod > /dev/null 2>&1

# ---------- Step 9: Smoke test ----------
echo "[9/9] Smoke testing…"
sleep 5
fail=0
check() {
    local want="$1"; shift
    local code; code=$(curl -s -o /dev/null -w "%{http_code}" "$@")
    if [ "$code" = "$want" ]; then echo "      ✓ $* → $code"
    else echo "      ✗ $* → $code (want $want)"; fail=$((fail+1)); fi
}
check 200 "$SITE_URL/api/health"
check 200 "$SITE_URL/api/runtime-config"
check 400 -X POST "$SITE_URL/api/webhooks/stripe" -d '{}'

# ---------- Output ----------
ENV_FILE="$REPO_PATH/.env.deploy.${PROJECT_NAME}"
cat > "$ENV_FILE" <<EOF
# Sellf deploy: $PROJECT_NAME (Netlify)
# Generated by install-netlify.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
SITE_URL=$SITE_URL
NETLIFY_SITE_ID=$SITE_ID
SUPABASE_URL=$SB_URL
SUPABASE_PROJECT_REF=$PROJECT_REF
SUPABASE_DB_PASSWORD=$DB_PASS
SUPABASE_ANON_KEY=$SB_ANON
SUPABASE_SERVICE_ROLE_KEY=$SB_SVC
STRIPE_WEBHOOK_ID=$WH_ID
STRIPE_WEBHOOK_SECRET=$WH_SECRET
CHECKOUT_BINDING_SECRET=$CHECKOUT_BINDING_SECRET
APP_ENCRYPTION_KEY=$APP_ENCRYPTION_KEY
LOGINWALL_SECRET=$LOGINWALL_SECRET
EOF
chmod 600 "$ENV_FILE"

echo ""
if [ "$fail" = "0" ]; then
    echo "✅ Deploy complete — $SITE_URL"
else
    echo "⚠️  Deploy finished but $fail smoke test(s) failed. Inspect:"
    echo "   netlify logs"
fi
echo "   Credentials saved to: $ENV_FILE  (chmod 600)"
echo ""
echo "   Stripe events (test mode): https://dashboard.stripe.com/test/webhooks/$WH_ID"
echo "   Supabase dashboard:        https://supabase.com/dashboard/project/$PROJECT_REF"
echo "   Netlify dashboard:         https://app.netlify.com/projects/$PROJECT_NAME"
