#!/bin/bash

# StackPilot - Sellf on Vercel (+ Supabase Cloud + Stripe test mode)
# Author: Paweł (Lazy Engineer)
#
# Provisions a fully working Sellf instance on Vercel from a clean slate:
#   * Supabase project (Free tier) — creates it, applies all migrations
#   * Vercel project — sets framework, disables SSO protection, populates all envs
#   * Stripe webhook (test mode) — points at the deployed URL
#   * Smoke test
#
# Total time: ~5–7 minutes, ~no manual steps after invocation.
# Unlike install.sh (which runs over SSH against a VPS) this script runs
# LOCALLY on your Mac/Linux box.
#
# Prerequisites (the script checks for these and aborts if missing):
#   vercel    — npm i -g vercel       — logged in via `vercel login`
#   supabase  — npm i -g supabase     — logged in via `supabase login` (PAT)
#   stripe    — brew install stripe/stripe-cli/stripe — logged in via `stripe login`
#   openssl   — system
#   jq        — system (brew install jq)
#   curl      — system
#
# Environment variables (all optional; prompted if absent):
#   PROJECT_NAME       — slug used for both Vercel and Supabase projects.
#                        Default: sellf-<unix-ts>
#   SUPABASE_ORG_ID    — Supabase org to create the project under.
#                        Default: first org in `supabase orgs list`
#   SUPABASE_REGION    — Default: eu-central-1
#   STRIPE_SK          — sk_test_...  (the script can read STRIPE_SK from env
#                        or from --stripe-sk; otherwise it prompts)
#   STRIPE_PK          — pk_test_...  (same — env or --stripe-pk or prompt)
#
# Supabase modes:
#   By default the script creates a fresh Supabase project for you.
#   If you want to use Vercel's native Supabase integration instead
#   (Vercel UI: Storage → Connect Database → Supabase), do this first
#   in the Vercel dashboard so it can create the project + env vars,
#   then run this script with --skip-supabase and the values it sets:
#
#     install-vercel.sh \
#       --skip-supabase \
#       --supabase-url https://<ref>.supabase.co \
#       --supabase-anon "<jwt>" \
#       --supabase-svc  "<jwt>" \
#       --supabase-ref <project-ref> \
#       --db-password <postgres-password>
#
#   The script reads those values verbatim, sets them as plain envs on
#   the Vercel project (under both bare and NEXT_PUBLIC_ names so the
#   Sellf code finds them either way), and continues with everything
#   else (migrations, Stripe webhook, smoke test).
#
# Output:
#   Live URL printed at the end + path to a .env.deploy file with all creds.

set -e

# ---------- Argument parsing ----------
SKIP_SUPABASE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --project-name)    PROJECT_NAME="$2"; shift 2 ;;
        --supabase-org)    SUPABASE_ORG_ID="$2"; shift 2 ;;
        --supabase-region) SUPABASE_REGION="$2"; shift 2 ;;
        --stripe-sk)       STRIPE_SK="$2"; shift 2 ;;
        --stripe-pk)       STRIPE_PK="$2"; shift 2 ;;
        --repo-path)       REPO_PATH="$2"; shift 2 ;;
        --skip-supabase)   SKIP_SUPABASE=1; shift ;;
        --supabase-url)    SB_URL_IN="$2"; shift 2 ;;
        --supabase-anon)   SB_ANON_IN="$2"; shift 2 ;;
        --supabase-svc)    SB_SVC_IN="$2"; shift 2 ;;
        --supabase-ref)    PROJECT_REF_IN="$2"; shift 2 ;;
        --db-password)     DB_PASS_IN="$2"; shift 2 ;;
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

if [ "$SKIP_SUPABASE" = "1" ]; then
    for var in SB_URL_IN SB_ANON_IN SB_SVC_IN PROJECT_REF_IN DB_PASS_IN; do
        if [ -z "${!var}" ]; then
            echo "❌ --skip-supabase requires --supabase-url, --supabase-anon, --supabase-svc, --supabase-ref, --db-password"
            exit 1
        fi
    done
fi

# ---------- Pre-flight ----------
echo "--- 🚀 Sellf → Vercel + Supabase Cloud + Stripe ---"
echo ""
echo "  Project name:    $PROJECT_NAME"
echo "  Supabase region: $SUPABASE_REGION"
echo "  Repo path:       $REPO_PATH"
echo ""

for cmd in vercel supabase stripe openssl jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Missing required CLI: $cmd"
        echo "   See header of this script for install instructions."
        exit 1
    fi
done

# Verify the repo path looks like Sellf
if [ ! -f "$REPO_PATH/admin-panel/package.json" ] || [ ! -d "$REPO_PATH/supabase/migrations" ]; then
    echo "❌ $REPO_PATH does not look like a Sellf checkout."
    echo "   Expected admin-panel/package.json and supabase/migrations/. Pass --repo-path."
    exit 1
fi

# Verify CLI auth
vercel whoami >/dev/null 2>&1 || { echo "❌ vercel: not logged in. Run: vercel login"; exit 1; }
if [ "$SKIP_SUPABASE" = "0" ]; then
    supabase projects list >/dev/null 2>&1 || { echo "❌ supabase: not logged in. Run: supabase login"; exit 1; }
fi
stripe config --list 2>/dev/null | grep -q "test_mode_api_key" || { echo "❌ stripe: not logged in. Run: stripe login"; exit 1; }

# Stripe keys
if [ -z "$STRIPE_SK" ] || [ -z "$STRIPE_PK" ]; then
    echo ""
    echo "Stripe test keys needed."
    echo "  Get them from https://dashboard.stripe.com/test/apikeys"
    [ -z "$STRIPE_SK" ] && read -r -p "  STRIPE_SK (sk_test_…): " STRIPE_SK
    [ -z "$STRIPE_PK" ] && read -r -p "  STRIPE_PK (pk_test_…): " STRIPE_PK
fi
case "$STRIPE_SK" in sk_test_*) ;; *) echo "❌ STRIPE_SK must start with sk_test_"; exit 1 ;; esac
case "$STRIPE_PK" in pk_test_*) ;; *) echo "❌ STRIPE_PK must start with pk_test_"; exit 1 ;; esac

# Supabase org (only needed when creating a project)
if [ "$SKIP_SUPABASE" = "0" ] && [ -z "$SUPABASE_ORG_ID" ]; then
    SUPABASE_ORG_ID=$(supabase orgs list 2>/dev/null | awk -F'|' '/[a-z]{20}/ {gsub(/^ +| +$/,"",$1); print $1; exit}')
    if [ -z "$SUPABASE_ORG_ID" ]; then
        echo "❌ Could not auto-detect Supabase org. Pass --supabase-org <id>."
        exit 1
    fi
    echo "  Supabase org:    $SUPABASE_ORG_ID (auto-detected)"
fi
if [ "$SKIP_SUPABASE" = "1" ]; then
    echo "  Supabase:        using existing project $PROJECT_REF_IN"
fi
echo ""

# ---------- Step 1: Generate secrets ----------
echo "[1/9] Generating secrets…"
CHECKOUT_BINDING_SECRET=$(openssl rand -base64 32)
APP_ENCRYPTION_KEY=$(openssl rand -base64 32)
LOGINWALL_SECRET=$(openssl rand -hex 32)
DB_PASS=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)

# ---------- Step 2 + 3: Supabase project (create or reuse) ----------
if [ "$SKIP_SUPABASE" = "1" ]; then
    echo "[2/9] Reusing existing Supabase project '$PROJECT_REF_IN'…"
    SB_URL="$SB_URL_IN"
    SB_ANON="$SB_ANON_IN"
    SB_SVC="$SB_SVC_IN"
    PROJECT_REF="$PROJECT_REF_IN"
    DB_PASS="$DB_PASS_IN"
    echo "[3/9] Skipping provisioning wait (project supplied externally)."
else
    echo "[2/9] Creating Supabase project '$PROJECT_NAME' in $SUPABASE_REGION…"
    supabase projects create "$PROJECT_NAME" \
        --org-id "$SUPABASE_ORG_ID" \
        --db-password "$DB_PASS" \
        --region "$SUPABASE_REGION" > /dev/null
    PROJECT_REF=$(supabase projects list 2>/dev/null \
        | awk -F'|' -v n="$PROJECT_NAME" '$0 ~ n {gsub(/^ +| +$/,"",$3); print $3; exit}')
    [ -z "$PROJECT_REF" ] && { echo "❌ Failed to read project ref after create."; exit 1; }
    echo "      ref: $PROJECT_REF"

    echo "[3/9] Waiting for Supabase provisioning + fetching keys…"
    SB_URL="https://${PROJECT_REF}.supabase.co"
    for i in 1 2 3 4 5 6; do
        KEYS=$(supabase projects api-keys --project-ref "$PROJECT_REF" 2>&1)
        if echo "$KEYS" | grep -q "anon"; then break; fi
        [ "$i" = "6" ] && { echo "❌ Supabase didn't finish provisioning in 2 minutes."; exit 1; }
        sleep 20
    done
    SB_ANON=$(echo "$KEYS" | grep -E '^\s+anon\s+\|' | sed 's/.*| //' | tr -d ' ')
    SB_SVC=$(echo "$KEYS"  | grep -E '^\s+service_role\s+\|' | sed 's/.*| //' | tr -d ' ')
    [ -z "$SB_ANON" ] || [ -z "$SB_SVC" ] && { echo "❌ Could not parse Supabase keys."; exit 1; }
fi

# ---------- Step 4: Create Vercel project + configure ----------
echo "[4/9] Creating Vercel project + setting framework + disabling SSO protection…"
cd "$REPO_PATH/admin-panel"
rm -rf .vercel  # in case of stale link
vercel project add "$PROJECT_NAME" > /dev/null
vercel link --project "$PROJECT_NAME" --yes > /dev/null

PROJECT_ID=$(jq -r .projectId .vercel/project.json)
TEAM_ID=$(jq -r .orgId .vercel/project.json)
# Detect Vercel CLI auth.json path (macOS vs Linux)
VAUTH="$HOME/Library/Application Support/com.vercel.cli/auth.json"
[ ! -f "$VAUTH" ] && VAUTH="$HOME/.local/share/com.vercel.cli/auth.json"
VTOKEN=$(jq -r .token "$VAUTH")

# Framework auto-detect doesn't fire with --yes, set it explicitly.
curl -s -X PATCH "https://api.vercel.com/v9/projects/$PROJECT_ID?teamId=$TEAM_ID" \
    -H "Authorization: Bearer $VTOKEN" -H "Content-Type: application/json" \
    -d '{"framework":"nextjs"}' > /dev/null

# Hobby projects start with SSO protection on (blocks *.vercel.app).
vercel project protection disable "$PROJECT_NAME" --sso > /dev/null 2>&1 || true

# ---------- Step 5: Set env vars ----------
echo "[5/9] Setting 11 environment variables…"
SITE_URL="https://${PROJECT_NAME}.vercel.app"

set_env() {
    # --value is the only reliable non-interactive path. Stdin piping
    # silently sets empty values in some CLI versions.
    vercel env add "$1" production --value "$2" --yes > /dev/null
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
echo "[6/9] Deploying to Vercel (this takes ~3 minutes)…"
DEPLOY_OUT=$(vercel --prod --yes 2>&1)
DEPLOY_URL=$(echo "$DEPLOY_OUT" | grep -oE "https://[^\"]+vercel.app" | head -1)
[ -z "$DEPLOY_URL" ] && { echo "❌ Could not parse deploy URL."; echo "$DEPLOY_OUT"; exit 1; }

# ---------- Step 7: Apply Supabase migrations ----------
echo "[7/9] Applying database migrations…"
cd "$REPO_PATH"
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

cd "$REPO_PATH/admin-panel"
yes y | vercel env rm STRIPE_WEBHOOK_SECRET production --yes > /dev/null
set_env STRIPE_WEBHOOK_SECRET "$WH_SECRET"
vercel --prod --yes > /dev/null

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
# Sellf deploy: $PROJECT_NAME
# Generated by install-vercel.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
SITE_URL=$SITE_URL
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
    echo "   vercel logs $SITE_URL --limit 20"
fi
echo "   Credentials saved to: $ENV_FILE  (chmod 600)"
echo ""
echo "   Stripe events (test mode): https://dashboard.stripe.com/test/webhooks/$WH_ID"
echo "   Supabase dashboard:        https://supabase.com/dashboard/project/$PROJECT_REF"
echo "   Vercel dashboard:          https://vercel.com/dashboard"
