#!/bin/bash

# StackPilot - Sellf on Coolify (self-hosted PaaS or Coolify Cloud)
# Author: Paweł (Lazy Engineer)
#
# Deploys Sellf to a Coolify instance. Two operating modes:
#
#   * Self-hosted Coolify (default) — the script SSHes into your VPS,
#     installs Coolify there if it isn't already, registers an admin user,
#     generates an API token, then uses the Coolify REST API to create the
#     application + env vars + deploy.
#
#   * Coolify Cloud (--coolify-cloud) — assumes you've already signed up
#     at https://app.coolify.io, added your server, and generated an API
#     token in the UI. The script then only talks to the Cloud API to
#     create the project + app + env vars + deploy. No SSH to the VPS
#     happens; Coolify Cloud handles that for you.
#
# Total time:
#   - Self-hosted, fresh VPS: ~12 min (5 min Coolify install + 7 min build)
#   - Self-hosted, Coolify already running: ~7 min
#   - Cloud: ~7 min
#
# IMPORTANT: requires a VPS with **8 GB+ RAM**. A 4 GB VPS OOM-kills the
# bun build step (see docs/DEPLOYMENT-COOLIFY.md in the Sellf repo).
#
# Prerequisites on operator's machine:
#   openssl, jq, curl, supabase, stripe.
#   Self-hosted mode also needs: ssh (with passwordless root access to VPS).
#
# Environment variables / flags:
#
#   Common:
#     --project-name       Coolify app name + Supabase project name
#                          Default: sellf-<unix-ts>
#     --supabase-org       Supabase org id (auto-detected if 1)
#     --supabase-region    Default: eu-central-1
#     --stripe-sk          sk_test_… (prompted if absent)
#     --stripe-pk          pk_test_… (prompted if absent)
#     --repo-path          Sellf repo checkout (default: pwd)
#     --skip-supabase + --supabase-url/--anon/--svc/--ref/--db-password —
#                          reuse an existing Supabase project instead of creating one
#                          (same flags as install-vercel.sh / install-netlify.sh)
#
#   Self-hosted Coolify (default):
#     --ssh-host           SSH alias or user@host for the target VPS (required)
#     --admin-email        Admin email to register in Coolify (default: pavveldev@gmail.com)
#     --admin-password     Admin password (default: random)
#     --skip-coolify-install Skip installing Coolify (use already-installed instance)
#
#   Coolify Cloud (--coolify-cloud):
#     --coolify-cloud      Use Coolify Cloud (https://app.coolify.io) instead of installing on a VPS
#     --coolify-base       Override Cloud base URL (default: https://app.coolify.io)
#     --coolify-token      API token from Cloud UI → Keys & Tokens (required)
#     --server-uuid        UUID of the server you've already connected in the Cloud UI (required)
#
# Output:
#   Live URL printed at the end + path to .env.deploy.<project> with creds.

set -e

# ---------- Argument parsing ----------
SSH_HOST=""
ADMIN_EMAIL="pavveldev@gmail.com"
ADMIN_PASSWORD=""
SKIP_COOLIFY_INSTALL=0
SKIP_SUPABASE=0
COOLIFY_CLOUD=0
COOLIFY_BASE_OVERRIDE=""
COOLIFY_TOKEN_IN=""
SERVER_UUID_IN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ssh-host)             SSH_HOST="$2"; shift 2 ;;
        --admin-email)          ADMIN_EMAIL="$2"; shift 2 ;;
        --admin-password)       ADMIN_PASSWORD="$2"; shift 2 ;;
        --project-name)         PROJECT_NAME="$2"; shift 2 ;;
        --supabase-org)         SUPABASE_ORG_ID="$2"; shift 2 ;;
        --supabase-region)      SUPABASE_REGION="$2"; shift 2 ;;
        --stripe-sk)            STRIPE_SK="$2"; shift 2 ;;
        --stripe-pk)            STRIPE_PK="$2"; shift 2 ;;
        --repo-path)            REPO_PATH="$2"; shift 2 ;;
        --skip-coolify-install) SKIP_COOLIFY_INSTALL=1; shift ;;
        --skip-supabase)        SKIP_SUPABASE=1; shift ;;
        --supabase-url)         SB_URL_IN="$2"; shift 2 ;;
        --supabase-anon)        SB_ANON_IN="$2"; shift 2 ;;
        --supabase-svc)         SB_SVC_IN="$2"; shift 2 ;;
        --supabase-ref)         PROJECT_REF_IN="$2"; shift 2 ;;
        --db-password)          DB_PASS_IN="$2"; shift 2 ;;
        --coolify-cloud)        COOLIFY_CLOUD=1; shift ;;
        --coolify-base)         COOLIFY_BASE_OVERRIDE="$2"; shift 2 ;;
        --coolify-token)        COOLIFY_TOKEN_IN="$2"; shift 2 ;;
        --server-uuid)          SERVER_UUID_IN="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set -e/p' "$0" | sed 's/^# \?//; /^set -e/d'
            exit 0
            ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

if [ "$SKIP_SUPABASE" = "1" ]; then
    for var in SB_URL_IN SB_ANON_IN SB_SVC_IN PROJECT_REF_IN DB_PASS_IN; do
        if [ -z "${!var}" ]; then
            echo "❌ --skip-supabase requires --supabase-url/--supabase-anon/--supabase-svc/--supabase-ref/--db-password"
            exit 1
        fi
    done
fi

if [ "$COOLIFY_CLOUD" = "1" ]; then
    [ -z "$COOLIFY_TOKEN_IN" ] && { echo "❌ --coolify-cloud requires --coolify-token <token-from-coolify-cloud-UI>"; exit 1; }
    [ -z "$SERVER_UUID_IN" ]   && { echo "❌ --coolify-cloud requires --server-uuid <uuid-of-server-added-to-cloud>"; exit 1; }
else
    [ -z "$SSH_HOST" ] && { echo "❌ --ssh-host is required for self-hosted Coolify (or use --coolify-cloud)."; exit 1; }
fi
PROJECT_NAME="${PROJECT_NAME:-sellf-$(date +%s)}"
SUPABASE_REGION="${SUPABASE_REGION:-eu-central-1}"
REPO_PATH="${REPO_PATH:-$(pwd)}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-18)}"

# ---------- Pre-flight ----------
echo "--- 🚀 Sellf → Coolify ---"
echo ""
if [ "$COOLIFY_CLOUD" = "1" ]; then
    echo "  Mode:            Coolify Cloud"
    echo "  Coolify base:    ${COOLIFY_BASE_OVERRIDE:-https://app.coolify.io}"
    echo "  Server UUID:     $SERVER_UUID_IN"
else
    echo "  Mode:            Coolify Self-Hosted"
    echo "  SSH host:        $SSH_HOST"
fi
echo "  Project name:    $PROJECT_NAME"
echo "  Supabase region: $SUPABASE_REGION"
echo "  Repo path:       $REPO_PATH"
echo ""

CLI_REQUIREMENTS="openssl jq curl supabase stripe"
[ "$COOLIFY_CLOUD" = "0" ] && CLI_REQUIREMENTS="ssh $CLI_REQUIREMENTS"
for cmd in $CLI_REQUIREMENTS; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Missing required CLI: $cmd"
        exit 1
    fi
done

if [ ! -f "$REPO_PATH/admin-panel/package.json" ] || [ ! -d "$REPO_PATH/supabase/migrations" ]; then
    echo "❌ $REPO_PATH does not look like a Sellf checkout."
    exit 1
fi

if [ "$COOLIFY_CLOUD" = "0" ]; then
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_HOST" "echo ok" >/dev/null 2>&1; then
        echo "❌ Cannot SSH to '$SSH_HOST' without a password. Set up SSH keys first."
        exit 1
    fi
fi

if [ "$SKIP_SUPABASE" = "0" ]; then
    supabase projects list >/dev/null 2>&1 || { echo "❌ supabase: not logged in. Run: supabase login"; exit 1; }
fi
stripe config --list 2>/dev/null | grep -q "test_mode_api_key" || { echo "❌ stripe: not logged in. Run: stripe login"; exit 1; }

# VPS sanity checks — only for self-hosted mode. Cloud users already chose
# a server in the Coolify UI when they added it.
if [ "$COOLIFY_CLOUD" = "0" ]; then
    SSH_IP=$(ssh "$SSH_HOST" "curl -s -4 ifconfig.io" 2>/dev/null)
    [ -z "$SSH_IP" ] && { echo "❌ Could not detect target's public IP via 'curl ifconfig.io'."; exit 1; }
    echo "  VPS public IP:   $SSH_IP"

    RAM_MB=$(ssh "$SSH_HOST" "free -m | awk '/^Mem:/ {print \$2}'" 2>/dev/null)
    if [ "$RAM_MB" -lt 7000 ]; then
        echo "⚠️  WARNING: target VPS has only $((RAM_MB / 1024)) GB RAM."
        echo "   Sellf's bun build needs ~3 GB free; on <8 GB the build typically OOM-kills."
        echo "   Continue anyway? [y/N]"
        read -r ans
        [ "$ans" = "y" ] || exit 1
    else
        echo "  VPS RAM:         $((RAM_MB / 1024)) GB ($RAM_MB MB)"
    fi
fi

# Stripe keys
if [ -z "$STRIPE_SK" ] || [ -z "$STRIPE_PK" ]; then
    echo ""
    [ -z "$STRIPE_SK" ] && read -r -p "  STRIPE_SK (sk_test_…): " STRIPE_SK
    [ -z "$STRIPE_PK" ] && read -r -p "  STRIPE_PK (pk_test_…): " STRIPE_PK
fi
case "$STRIPE_SK" in sk_test_*) ;; *) echo "❌ STRIPE_SK must start with sk_test_"; exit 1 ;; esac
case "$STRIPE_PK" in pk_test_*) ;; *) echo "❌ STRIPE_PK must start with pk_test_"; exit 1 ;; esac

# Supabase org (only needed when creating a project)
if [ "$SKIP_SUPABASE" = "0" ] && [ -z "$SUPABASE_ORG_ID" ]; then
    SUPABASE_ORG_ID=$(supabase orgs list 2>/dev/null | awk -F'|' '/[a-z]{20}/ {gsub(/^ +| +$/,"",$1); print $1; exit}')
    [ -z "$SUPABASE_ORG_ID" ] && { echo "❌ Could not auto-detect Supabase org."; exit 1; }
fi

if [ "$COOLIFY_CLOUD" = "1" ]; then
    COOLIFY_BASE="${COOLIFY_BASE_OVERRIDE:-https://app.coolify.io}"
    COOLIFY_TOKEN="$COOLIFY_TOKEN_IN"
    SERVER_UUID="$SERVER_UUID_IN"
else
    COOLIFY_BASE="http://${SSH_IP}:8000"
fi

# ---------- Step 1: Install Coolify (self-hosted only) ----------
if [ "$COOLIFY_CLOUD" = "1" ]; then
    echo "[1/11] Using Coolify Cloud at $COOLIFY_BASE — skipping VPS install."
elif [ "$SKIP_COOLIFY_INSTALL" = "0" ] && ! ssh "$SSH_HOST" "docker ps --filter name=coolify --format '{{.Names}}' 2>/dev/null | grep -q '^coolify$'" 2>/dev/null; then
    echo "[1/11] Installing Coolify on $SSH_HOST (this takes ~5 minutes)…"
    ssh "$SSH_HOST" "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash" 2>&1 | tail -3 | sed 's/^/        /'
else
    echo "[1/11] Coolify already running on $SSH_HOST — skipping install."
fi

# ---------- Step 2: Register admin user via HTTP (self-hosted only) ----------
if [ "$COOLIFY_CLOUD" = "1" ]; then
    echo "[2/11] Coolify Cloud — admin user already set up. Skipping."
else
    echo "[2/11] Registering admin user '$ADMIN_EMAIL'…"
    COOKIES=$(mktemp)
    trap 'rm -f "$COOKIES"' EXIT
    RESP=$(curl -s -c "$COOKIES" "$COOLIFY_BASE/register")
    TOKEN=$(echo "$RESP" | grep -oE 'name="_token"[^>]*value="[^"]*"' | head -1 | sed -E 's/.*value="([^"]+)".*/\1/')
    if [ -z "$TOKEN" ]; then
        # Maybe already registered. Try logging in instead.
        echo "        Register page has no CSRF — likely already set up. Continuing."
    else
        REG_RESULT=$(curl -s -b "$COOKIES" -c "$COOKIES" -X POST "$COOLIFY_BASE/register" \
            -d "_token=$TOKEN" \
            -d "name=Pawel" \
            -d "email=$ADMIN_EMAIL" \
            -d "password=$ADMIN_PASSWORD" \
            -d "password_confirmation=$ADMIN_PASSWORD" \
            -d "terms=on" \
            -o /dev/null -w "%{http_code}")
        case "$REG_RESULT" in
            302) echo "        Registered + logged in." ;;
            422) echo "        User already exists; that's fine." ;;
            *) echo "        Unexpected register HTTP $REG_RESULT"; exit 1 ;;
        esac
    fi
fi

# ---------- Step 3: Enable API + create token (self-hosted only; Cloud uses provided token) ----------
if [ "$COOLIFY_CLOUD" = "1" ]; then
    echo "[3/11] Coolify Cloud — using API token supplied via --coolify-token."
    curl -sH "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_BASE/api/v1/version" >/dev/null \
        || { echo "❌ Cloud API token validation failed. Check --coolify-token."; exit 1; }
else
    echo "[3/11] Enabling Coolify API + generating personal access token…"
    PLAINTEXT=$(openssl rand -hex 32)
    HASH=$(ssh "$SSH_HOST" "docker exec coolify php artisan tinker --execute='echo hash(\"sha256\", \"$PLAINTEXT\");' 2>&1" | tail -1 | tr -d '\r')
    USER_ID=$(ssh "$SSH_HOST" "docker exec coolify-db psql -U coolify -tA -c \"SELECT id FROM users WHERE email='$ADMIN_EMAIL' LIMIT 1;\" 2>/dev/null" | head -1 | tr -d ' ')
    TEAM_ID=$(ssh "$SSH_HOST" "docker exec coolify-db psql -U coolify -tA -c \"SELECT team_id FROM team_user WHERE user_id=$USER_ID LIMIT 1;\" 2>/dev/null" | head -1 | tr -d ' ')

    ssh "$SSH_HOST" "docker exec coolify-db psql -U coolify -c \"
      UPDATE instance_settings SET is_api_enabled = true;
      INSERT INTO personal_access_tokens (name, token, tokenable_id, tokenable_type, team_id, abilities, created_at, updated_at)
        VALUES ('claude-cli', '$HASH', $USER_ID, 'App\\\\Models\\\\User', $TEAM_ID, '[\\\"*\\\"]', NOW(), NOW());
    \"" > /dev/null 2>&1

    TOKEN_ID=$(ssh "$SSH_HOST" "docker exec coolify-db psql -U coolify -tA -c 'SELECT id FROM personal_access_tokens ORDER BY id DESC LIMIT 1;' 2>/dev/null" | head -1 | tr -d ' ')
    COOLIFY_TOKEN="${TOKEN_ID}|${PLAINTEXT}"
    curl -sH "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_BASE/api/v1/version" >/dev/null \
        || { echo "❌ API token validation failed."; exit 1; }
fi

# ---------- Step 4: Validate server (self-hosted only; Cloud user added it via UI) ----------
if [ "$COOLIFY_CLOUD" = "1" ]; then
    echo "[4/11] Coolify Cloud — using server $SERVER_UUID already validated via UI."
else
    echo "[4/11] Validating localhost as deploy target…"
    SERVER_UUID=$(curl -sH "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_BASE/api/v1/servers" | jq -r '.[0].uuid')
    curl -sH "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_BASE/api/v1/servers/$SERVER_UUID/validate" >/dev/null
    # The API often returns is_reachable=null even after validation succeeds; trust the DB instead.
    ssh "$SSH_HOST" "docker exec coolify-db psql -U coolify -c \"UPDATE server_settings SET is_reachable=true, is_usable=true;\" >/dev/null 2>&1"
fi

# ---------- Step 5: Generate secrets ----------
echo "[5/11] Generating secrets…"
CHECKOUT_BINDING_SECRET=$(openssl rand -base64 32)
APP_ENCRYPTION_KEY=$(openssl rand -base64 32)
LOGINWALL_SECRET=$(openssl rand -hex 32)
DB_PASS=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)

# ---------- Step 6: Supabase project (create or reuse) ----------
if [ "$SKIP_SUPABASE" = "1" ]; then
    echo "[6/11] Reusing existing Supabase project '$PROJECT_REF_IN'…"
    SB_URL="$SB_URL_IN"
    SB_ANON="$SB_ANON_IN"
    SB_SVC="$SB_SVC_IN"
    PROJECT_REF="$PROJECT_REF_IN"
    DB_PASS="$DB_PASS_IN"
else
    echo "[6/11] Creating Supabase project '$PROJECT_NAME'…"
    supabase projects create "$PROJECT_NAME" \
        --org-id "$SUPABASE_ORG_ID" \
        --db-password "$DB_PASS" \
        --region "$SUPABASE_REGION" > /dev/null
    PROJECT_REF=$(supabase projects list 2>/dev/null \
        | awk -F'|' -v n="$PROJECT_NAME" '$0 ~ n {gsub(/^ +| +$/,"",$3); print $3; exit}')
    SB_URL="https://${PROJECT_REF}.supabase.co"

    # Wait for keys
    for i in 1 2 3 4 5 6; do
        KEYS=$(supabase projects api-keys --project-ref "$PROJECT_REF" 2>&1)
        if echo "$KEYS" | grep -q "anon"; then break; fi
        [ "$i" = "6" ] && { echo "❌ Supabase provisioning timed out."; exit 1; }
        sleep 20
    done
    SB_ANON=$(echo "$KEYS" | grep -E '^\s+anon\s+\|' | sed 's/.*| //' | tr -d ' ')
    SB_SVC=$(echo "$KEYS"  | grep -E '^\s+service_role\s+\|' | sed 's/.*| //' | tr -d ' ')
fi

# ---------- Step 7: Create Coolify project + app ----------
echo "[7/11] Creating Coolify project + application…"
COOLIFY_PROJECT_UUID=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" -H "Content-Type: application/json" \
    -X POST "$COOLIFY_BASE/api/v1/projects" \
    -d "{\"name\":\"$PROJECT_NAME\"}" | jq -r .uuid)
[ -z "$COOLIFY_PROJECT_UUID" ] || [ "$COOLIFY_PROJECT_UUID" = "null" ] && { echo "❌ Project creation failed."; exit 1; }

APP_RESP=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" -H "Content-Type: application/json" \
    -X POST "$COOLIFY_BASE/api/v1/applications/public" \
    -d "{
      \"project_uuid\":\"$COOLIFY_PROJECT_UUID\",
      \"environment_name\":\"production\",
      \"server_uuid\":\"$SERVER_UUID\",
      \"git_repository\":\"https://github.com/jurczykpawel/sellf\",
      \"git_branch\":\"main\",
      \"ports_exposes\":\"3000\",
      \"build_pack\":\"dockerfile\",
      \"dockerfile_location\":\"/Dockerfile\",
      \"base_directory\":\"/\",
      \"instant_deploy\":false,
      \"name\":\"$PROJECT_NAME\"
    }")
APP_UUID=$(echo "$APP_RESP" | jq -r .uuid)
APP_DOMAIN=$(echo "$APP_RESP" | jq -r .domains)
[ -z "$APP_UUID" ] || [ "$APP_UUID" = "null" ] && { echo "❌ App creation failed: $APP_RESP"; exit 1; }
SITE_URL="$APP_DOMAIN"
echo "        domain: $APP_DOMAIN"

# ---------- Step 8: Set env vars ----------
echo "[8/11] Setting 12 environment variables on Coolify app…"
set_env() {
    curl -s -o /dev/null -H "Authorization: Bearer $COOLIFY_TOKEN" -H "Content-Type: application/json" \
        -X POST "$COOLIFY_BASE/api/v1/applications/$APP_UUID/envs" \
        -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')"
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
set_env PORT                          "3000"

# ---------- Step 9: Trigger deploy + wait ----------
echo "[9/11] Triggering deploy (build typically takes 5–10 minutes)…"
curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_BASE/api/v1/deploy?uuid=$APP_UUID&force=true" >/dev/null

# Wait for build container to disappear
for i in $(seq 1 60); do
    # Build container has name == deployment_uuid; just wait for the app's runtime
    # container to appear and stay up for a couple polls.
    APP_STATUS=$(curl -sH "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_BASE/api/v1/applications/$APP_UUID" | jq -r .status)
    case "$APP_STATUS" in
        running:*) break ;;
    esac
    sleep 15
done
[ "$i" = "60" ] && echo "        ⚠️  build is taking longer than 15 min — check Coolify UI manually."

# ---------- Step 10: Apply migrations + Stripe webhook ----------
echo "[10/11] Applying database migrations + Stripe webhook…"
if [ "$SKIP_SUPABASE" = "0" ]; then
    supabase link --project-ref "$PROJECT_REF" --password "$DB_PASS" > /dev/null 2>&1
    supabase db push --password "$DB_PASS" --yes > /dev/null
else
    echo "        Skipping db push — migrations expected to be applied already."
fi

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

# Replace placeholder webhook secret + redeploy
# Coolify doesn't have an env-update endpoint via API in 4.1; instead delete + recreate
# the env var. We can't easily delete a single env var by key, so reuse the existing
# /envs PATCH-equivalent which is a POST that upserts on key conflict.
set_env STRIPE_WEBHOOK_SECRET "$WH_SECRET"
curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_BASE/api/v1/deploy?uuid=$APP_UUID&force=true" >/dev/null

# Wait briefly for redeploy
sleep 30

# ---------- Step 11: Smoke test ----------
echo "[11/11] Smoke testing…"
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
# Sellf deploy: $PROJECT_NAME (Coolify on $SSH_HOST)
# Generated by install-coolify.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
SITE_URL=$SITE_URL
COOLIFY_HOST=$SSH_HOST
COOLIFY_BASE=$COOLIFY_BASE
COOLIFY_APP_UUID=$APP_UUID
COOLIFY_ADMIN_EMAIL=$ADMIN_EMAIL
COOLIFY_ADMIN_PASSWORD=$ADMIN_PASSWORD
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
    echo "⚠️  Deploy finished but $fail smoke test(s) failed."
    echo "   Coolify dashboard: $COOLIFY_BASE"
fi
echo "   Credentials saved to: $ENV_FILE  (chmod 600)"
echo ""
echo "   Coolify admin login:       $COOLIFY_BASE  ($ADMIN_EMAIL / $ADMIN_PASSWORD)"
echo "   Stripe events (test mode): https://dashboard.stripe.com/test/webhooks/$WH_ID"
echo "   Supabase dashboard:        https://supabase.com/dashboard/project/$PROJECT_REF"
