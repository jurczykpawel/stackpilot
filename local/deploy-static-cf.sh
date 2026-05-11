#!/bin/bash

# StackPilot - Deploy Static Site to Cloudflare Pages
# Auto-detects a static site generator, builds the project, and deploys to
# Cloudflare Pages via Wrangler.
#
# Supported (auto-detected):
#   Astro, Next.js (static export), Hugo, Eleventy (11ty),
#   SvelteKit (static), Gatsby, Docusaurus, VitePress, MkDocs
#
# Author: Pawel (Lazy Engineer)
#
# Usage:
#   ./local/deploy-static-cf.sh DOMAIN [PROJECT_NAME] [PROJECT_DIR]
#
# Examples:
#   cd my-astro-site
#   ./local/deploy-static-cf.sh my-site.com
#
#   ./local/deploy-static-cf.sh my-site.com my-cf-project ./my-astro-site
#
# Required configuration (one of):
#   1. Env vars: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID
#   2. Config file: ~/.config/cloudflare/config with API_TOKEN= and ACCOUNT_ID=
#
# Token permissions required:
#   - Account → Cloudflare Pages → Edit
#   - User → User Details → Read (auto-included by template)

set -e

DOMAIN="$1"
PROJECT_NAME="$2"
PROJECT_DIR="${3:-.}"

# Colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

CONFIG_FILE="$HOME/.config/cloudflare/config"
CF_API="https://api.cloudflare.com/client/v4"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "--help" ] || [ "$DOMAIN" = "-h" ]; then
    cat <<EOF
Usage: $0 DOMAIN [PROJECT_NAME] [PROJECT_DIR]

Builds your static site and deploys it to Cloudflare Pages.

Arguments:
  DOMAIN         Custom domain to attach to the Pages project (e.g. example.com)
  PROJECT_NAME   Optional. Cloudflare Pages project slug.
                 Default: derived from DOMAIN (dots → dashes, max 58 chars).
  PROJECT_DIR    Optional. Directory of the source project. Default: . (cwd)

Configuration:
  Required env vars (or in ~/.config/cloudflare/config):
    CLOUDFLARE_API_TOKEN   API token with "Cloudflare Pages → Edit" scope
    CLOUDFLARE_ACCOUNT_ID  Your Cloudflare account ID

  First-time setup (interactive wizard):
    ./local/setup-cloudflare-pages.sh

  Missing setup → this script prints step-by-step instructions and exits.
  Detailed reference → docs/cloudflare-pages-deploy.md

Supported frameworks (auto-detected):
  Astro, Next.js (static export), Hugo, Eleventy,
  SvelteKit (static), Gatsby, Docusaurus, VitePress, MkDocs

Examples:
  cd my-astro-site
  $0 my-site.com

  $0 my-site.com my-cf-project ./my-astro-site
EOF
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/validation.sh"
source "$SCRIPT_DIR/../lib/framework-detect.sh"

sp_validate_domain "$DOMAIN" || exit 1

# ---------------------------------------------------------------------------
# Step 1 — Load credentials (env vars take priority, then config file)
# ---------------------------------------------------------------------------

API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"

if [ -z "$API_TOKEN" ] || [ -z "$ACCOUNT_ID" ]; then
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        # Read only API_TOKEN and ACCOUNT_ID from config (KEY=VALUE format).
        while IFS='=' read -r key val; do
            case "$key" in
                API_TOKEN)  [ -z "$API_TOKEN" ]  && API_TOKEN="$val" ;;
                ACCOUNT_ID) [ -z "$ACCOUNT_ID" ] && ACCOUNT_ID="$val" ;;
            esac
        done < <(grep -E '^(API_TOKEN|ACCOUNT_ID)=' "$CONFIG_FILE" 2>/dev/null)
    fi
fi

# ---------------------------------------------------------------------------
# Helper: print full setup instructions on missing/invalid credentials.
# ---------------------------------------------------------------------------

print_setup_instructions() {
    local reason="$1"
    echo ""
    echo -e "${RED}❌ Cloudflare Pages deploy is not configured.${NC}"
    echo -e "   Reason: ${reason}"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  One-time Cloudflare Pages setup${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}Step 1.${NC} Create an API token"
    echo "        Open: https://dash.cloudflare.com/profile/api-tokens"
    echo "        Click: \"Create Token\" → \"Create Custom Token\""
    echo "        Name:  stackpilot-pages"
    echo ""
    echo -e "${YELLOW}Step 2.${NC} Set permissions on the token"
    echo "        Account → Cloudflare Pages → Edit"
    echo "        User    → User Details     → Read   (auto-added by template)"
    echo "        Account → Account Settings → Read   (optional, for nicer errors)"
    echo "        Zone    → DNS              → Edit   (only if you want auto custom-domain attach)"
    echo ""
    echo -e "${YELLOW}Step 3.${NC} Restrict the scope (recommended)"
    echo "        Account Resources: Include → <your account>"
    echo "        Zone Resources:    Include → Specific zone → <your domain>  (if you added Zone:DNS)"
    echo ""
    echo -e "${YELLOW}Step 4.${NC} Click Continue → Create Token, then copy the token."
    echo ""
    echo -e "${YELLOW}Step 5.${NC} Get your Account ID"
    echo "        Open: https://dash.cloudflare.com → click on any domain (or stay on overview)"
    echo "        Look at the right sidebar: \"Account ID\" → copy it."
    echo ""
    echo -e "${YELLOW}Step 6.${NC} Save credentials. Pick ONE:"
    echo ""
    echo -e "        ${GREEN}Option A — env vars (current shell, temporary):${NC}"
    echo "            export CLOUDFLARE_API_TOKEN='your-token-here'"
    echo "            export CLOUDFLARE_ACCOUNT_ID='your-account-id-here'"
    echo ""
    echo -e "        ${GREEN}Option B — persistent in shell rc (recommended):${NC}"
    echo "            echo 'export CLOUDFLARE_API_TOKEN=your-token-here' >> ~/.zshenv"
    echo "            echo 'export CLOUDFLARE_ACCOUNT_ID=your-account-id-here' >> ~/.zshenv"
    echo "            source ~/.zshenv"
    echo ""
    echo -e "        ${GREEN}Option C — StackPilot config file:${NC}"
    echo "            mkdir -p ~/.config/cloudflare && chmod 700 ~/.config/cloudflare"
    echo "            cat >> ~/.config/cloudflare/config <<CFG"
    echo "            API_TOKEN=your-token-here"
    echo "            ACCOUNT_ID=your-account-id-here"
    echo "            CFG"
    echo "            chmod 600 ~/.config/cloudflare/config"
    echo ""
    echo -e "${YELLOW}Step 7.${NC} Re-run this command:"
    echo "            $0 $DOMAIN ${PROJECT_NAME:-} ${PROJECT_DIR:-.}"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Step 2 — Validate that credentials exist
# ---------------------------------------------------------------------------

if [ -z "$API_TOKEN" ] && [ -z "$ACCOUNT_ID" ]; then
    print_setup_instructions "missing CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID"
    exit 1
fi
if [ -z "$API_TOKEN" ]; then
    print_setup_instructions "missing CLOUDFLARE_API_TOKEN"
    exit 1
fi
if [ -z "$ACCOUNT_ID" ]; then
    print_setup_instructions "missing CLOUDFLARE_ACCOUNT_ID"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3 — Verify token is valid
# ---------------------------------------------------------------------------

echo ""
echo -e "${BLUE}🔐 Verifying Cloudflare credentials...${NC}"

VERIFY=$(curl -fsS "$CF_API/user/tokens/verify" \
    -H "Authorization: Bearer $API_TOKEN" 2>&1) || {
    print_setup_instructions "API token rejected by Cloudflare (network error or invalid token)"
    echo "Last API response:"
    echo "$VERIFY"
    exit 1
}

if ! echo "$VERIFY" | grep -q '"success":true'; then
    print_setup_instructions "API token is invalid or revoked"
    exit 1
fi
echo -e "${GREEN}   ✓ Token valid${NC}"

# ---------------------------------------------------------------------------
# Step 4 — Verify Pages:Edit permission by probing the projects endpoint.
#          200 = allowed (even with 0 projects).
#          403 / authentication_error = missing Pages scope.
# ---------------------------------------------------------------------------

PAGES_PROBE=$(curl -sS -o /tmp/sp-cf-pages-probe.$$.json -w "%{http_code}" \
    "$CF_API/accounts/$ACCOUNT_ID/pages/projects?per_page=1" \
    -H "Authorization: Bearer $API_TOKEN") || PAGES_PROBE="000"

PROBE_BODY="$(cat /tmp/sp-cf-pages-probe.$$.json 2>/dev/null || true)"
rm -f /tmp/sp-cf-pages-probe.$$.json

if [ "$PAGES_PROBE" = "404" ]; then
    print_setup_instructions "Account ID '$ACCOUNT_ID' not found (check Step 5 in the instructions)"
    exit 1
fi
if [ "$PAGES_PROBE" != "200" ]; then
    case "$PROBE_BODY" in
        *"Authentication error"*|*"authentication_error"*|*"code\":9109"*|*"code\":10000"*)
            print_setup_instructions "Token is missing 'Account → Cloudflare Pages → Edit' permission"
            ;;
        *)
            print_setup_instructions "Pages API probe failed (HTTP $PAGES_PROBE). Response: ${PROBE_BODY:0:200}"
            ;;
    esac
    exit 1
fi
echo -e "${GREEN}   ✓ Pages:Edit permission OK${NC}"
echo -e "${GREEN}   ✓ Account: ${ACCOUNT_ID:0:8}...${NC}"

# ---------------------------------------------------------------------------
# Step 5 — Verify wrangler is available
# ---------------------------------------------------------------------------

if ! command -v npx >/dev/null 2>&1; then
    echo ""
    echo -e "${RED}❌ npx is not installed.${NC}"
    echo "   Wrangler (Cloudflare's deploy CLI) needs npm/npx."
    echo ""
    echo "   Install Node.js LTS from https://nodejs.org/"
    echo "   or via Homebrew:   brew install node"
    echo "   or via nvm:        nvm install --lts"
    exit 1
fi
echo -e "${GREEN}   ✓ npx available${NC}"

# ---------------------------------------------------------------------------
# Step 6 — Resolve project paths and framework
# ---------------------------------------------------------------------------

if [ ! -d "$PROJECT_DIR" ]; then
    echo -e "${RED}❌ Project directory not found: $PROJECT_DIR${NC}"
    exit 1
fi

ABS_PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

if ! sp_detect_static_framework "$ABS_PROJECT_DIR"; then
    echo -e "${RED}❌ Could not detect a static site framework in: $ABS_PROJECT_DIR${NC}"
    echo ""
    echo "Supported: Astro, Next.js (static export), Hugo, Eleventy, SvelteKit (static),"
    echo "           Gatsby, Docusaurus, VitePress, MkDocs"
    echo ""
    echo "If your build is custom, build manually and run wrangler directly:"
    echo ""
    echo "    npx wrangler@latest pages deploy ./your-output-dir \\"
    echo "        --project-name=<slug> --branch=main"
    exit 1
fi

# Derive project name from domain if not provided.
# Cloudflare project slugs: lowercase letters, digits, dashes; max 58 chars.
if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME="$(echo "$DOMAIN" | tr '[:upper:].' '[:lower:]-' | sed 's/[^a-z0-9-]//g' | cut -c1-58)"
fi

if ! [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]{0,57}$ ]]; then
    echo -e "${RED}❌ Invalid project name: $PROJECT_NAME${NC}"
    echo "   Must be lowercase letters, digits, dashes; 1–58 chars; can't start with dash."
    exit 1
fi

echo ""
echo -e "${BLUE}🚀 StackPilot — Deploy to Cloudflare Pages${NC}"
echo ""
echo "   Framework:     $SP_FRAMEWORK"
echo "   Build cmd:     $SP_BUILD_CMD"
echo "   Output dir:    $SP_OUTPUT_DIR"
echo "   Project name:  $PROJECT_NAME"
echo "   Domain:        $DOMAIN"
echo "   Source:        $ABS_PROJECT_DIR"
echo ""

# ---------------------------------------------------------------------------
# Step 7 — Build
# ---------------------------------------------------------------------------

cd "$ABS_PROJECT_DIR"

echo -e "${BLUE}📦 Building (this can take 30s–2min)...${NC}"
if ! eval "$SP_BUILD_CMD"; then
    echo -e "${RED}❌ Build failed${NC}"
    exit 1
fi

if [ ! -d "$SP_OUTPUT_DIR" ]; then
    echo -e "${RED}❌ Build did not produce expected output directory: $SP_OUTPUT_DIR${NC}"
    echo "   Check your build configuration. Some frameworks allow customizing the output path."
    exit 1
fi
echo -e "${GREEN}✅ Build complete${NC}"
echo ""

# ---------------------------------------------------------------------------
# Step 8 — Ensure Pages project exists (create if missing)
# ---------------------------------------------------------------------------

echo -e "${BLUE}🔎 Checking Pages project '$PROJECT_NAME'...${NC}"

PROJECT_CHECK=$(curl -sS -o /tmp/sp-cf-pages-proj.$$.json -w "%{http_code}" \
    "$CF_API/accounts/$ACCOUNT_ID/pages/projects/$PROJECT_NAME" \
    -H "Authorization: Bearer $API_TOKEN") || PROJECT_CHECK="000"
PROJECT_BODY="$(cat /tmp/sp-cf-pages-proj.$$.json 2>/dev/null || true)"
rm -f /tmp/sp-cf-pages-proj.$$.json

if [ "$PROJECT_CHECK" = "200" ]; then
    echo -e "${GREEN}   ✓ Project exists${NC}"
elif [ "$PROJECT_CHECK" = "404" ]; then
    echo "   Project doesn't exist yet — creating..."
    CREATE_BODY=$(curl -fsS "$CF_API/accounts/$ACCOUNT_ID/pages/projects" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"name\":\"$PROJECT_NAME\",\"production_branch\":\"main\"}" 2>&1) || {
        echo -e "${RED}❌ Failed to create project: $CREATE_BODY${NC}"
        exit 1
    }
    echo -e "${GREEN}   ✓ Project created${NC}"
else
    echo -e "${RED}❌ Unexpected response while checking project (HTTP $PROJECT_CHECK)${NC}"
    echo "   $PROJECT_BODY"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 9 — Deploy via wrangler
# ---------------------------------------------------------------------------

echo ""
echo -e "${BLUE}☁️  Uploading to Cloudflare Pages via wrangler...${NC}"

# Pin to latest stable wrangler. Env vars are read by wrangler natively.
# --branch=main → production deployment.
if ! CLOUDFLARE_API_TOKEN="$API_TOKEN" CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID" \
    npx --yes wrangler@latest pages deploy "$SP_OUTPUT_DIR" \
        --project-name="$PROJECT_NAME" \
        --branch=main \
        --commit-dirty=true; then
    echo -e "${RED}❌ Deploy failed${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Deploy uploaded${NC}"

# ---------------------------------------------------------------------------
# Step 10 — Attach custom domain (idempotent)
# ---------------------------------------------------------------------------

echo ""
echo -e "${BLUE}🌐 Attaching custom domain '$DOMAIN'...${NC}"

# Skip attach for the default Cloudflare subdomain — it's reserved by CF
# and only used here as the project name. The default URL works out of the box.
if [[ "$DOMAIN" == *.pages.dev ]]; then
    echo -e "${GREEN}   ✓ Skipped — '*.pages.dev' is Cloudflare's default host${NC}"
    echo ""
    echo -e "${GREEN}🎉 Done.${NC}"
    echo ""
    echo "   Default URL:  https://$PROJECT_NAME.pages.dev"
    echo "   Dashboard:    https://dash.cloudflare.com/$ACCOUNT_ID/pages/view/$PROJECT_NAME"
    echo ""
    exit 0
fi

# --- Step 10a: attach domain (idempotent) ---
DOMAIN_CHECK=$(curl -sS -o /tmp/sp-cf-pages-dom.$$.json -w "%{http_code}" \
    "$CF_API/accounts/$ACCOUNT_ID/pages/projects/$PROJECT_NAME/domains/$DOMAIN" \
    -H "Authorization: Bearer $API_TOKEN") || DOMAIN_CHECK="000"
rm -f /tmp/sp-cf-pages-dom.$$.json

DOMAIN_ATTACHED=0
if [ "$DOMAIN_CHECK" = "200" ]; then
    echo -e "${GREEN}   ✓ Domain already attached${NC}"
    DOMAIN_ATTACHED=1
elif [ "$DOMAIN_CHECK" = "404" ]; then
    ATTACH_OUT=$(curl -sS -o /tmp/sp-cf-pages-att.$$.json -w "%{http_code}" \
        "$CF_API/accounts/$ACCOUNT_ID/pages/projects/$PROJECT_NAME/domains" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"name\":\"$DOMAIN\"}") || ATTACH_OUT="000"
    ATTACH_BODY="$(cat /tmp/sp-cf-pages-att.$$.json 2>/dev/null || true)"
    rm -f /tmp/sp-cf-pages-att.$$.json

    if [ "$ATTACH_OUT" = "200" ] || [ "$ATTACH_OUT" = "201" ]; then
        echo -e "${GREEN}   ✓ Domain attached${NC}"
        DOMAIN_ATTACHED=1
    else
        echo -e "${YELLOW}⚠️  Couldn't auto-attach domain (HTTP $ATTACH_OUT).${NC}"
        echo "   Body: ${ATTACH_BODY:0:300}"
        echo ""
        echo "   Attach manually in dashboard:"
        echo "   https://dash.cloudflare.com/$ACCOUNT_ID/pages/view/$PROJECT_NAME/domains"
    fi
else
    echo -e "${YELLOW}⚠️  Unexpected response while checking domain (HTTP $DOMAIN_CHECK).${NC}"
    echo "   Attach manually in dashboard:"
    echo "   https://dash.cloudflare.com/$ACCOUNT_ID/pages/view/$PROJECT_NAME/domains"
fi

# --- Step 10b: ensure CNAME exists (Zone:DNS:Edit needed) ---
# Runs both for freshly-attached domains and for already-attached ones,
# so it heals manually-deleted DNS records on re-runs.
if [ "$DOMAIN_ATTACHED" = "1" ]; then
    CNAME_TARGET="$PROJECT_NAME.pages.dev"
    ZONE_ID=""
    APEX_TRY="$DOMAIN"
    while true; do
        ZONE_LOOKUP=$(curl -fsS "$CF_API/zones?name=$APEX_TRY" \
            -H "Authorization: Bearer $API_TOKEN" 2>/dev/null) || ZONE_LOOKUP=""
        if [ -n "$ZONE_LOOKUP" ] && echo "$ZONE_LOOKUP" | grep -q '"success":true'; then
            ZONE_ID=$(echo "$ZONE_LOOKUP" | grep -oE '"id":"[a-f0-9]{32}"' | head -1 | sed 's/.*"id":"\([a-f0-9]\{32\}\)".*/\1/')
            if [ -n "$ZONE_ID" ]; then break; fi
        fi
        if [[ "$APEX_TRY" != *.* ]]; then break; fi
        APEX_TRY="${APEX_TRY#*.}"
    done

    if [ -n "$ZONE_ID" ]; then
        EXISTING=$(curl -fsS "$CF_API/zones/$ZONE_ID/dns_records?name=$DOMAIN" \
            -H "Authorization: Bearer $API_TOKEN" 2>/dev/null || true)
        if echo "$EXISTING" | grep -q "\"content\":\"$CNAME_TARGET\""; then
            echo -e "${GREEN}   ✓ CNAME already points at $CNAME_TARGET${NC}"
        elif echo "$EXISTING" | grep -q '"result":\[\]'; then
            CNAME_OUT=$(curl -sS -o /tmp/sp-cf-pages-cname.$$.json -w "%{http_code}" \
                "$CF_API/zones/$ZONE_ID/dns_records" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"CNAME\",\"name\":\"$DOMAIN\",\"content\":\"$CNAME_TARGET\",\"proxied\":true,\"ttl\":1}") \
                || CNAME_OUT="000"
            CNAME_BODY="$(cat /tmp/sp-cf-pages-cname.$$.json 2>/dev/null || true)"
            rm -f /tmp/sp-cf-pages-cname.$$.json

            if [ "$CNAME_OUT" = "200" ]; then
                echo -e "${GREEN}   ✓ CNAME created: $DOMAIN → $CNAME_TARGET (proxied)${NC}"
                echo "     TLS cert will issue within ~30s."
            else
                echo -e "${YELLOW}   ⚠ Couldn't auto-create CNAME (HTTP $CNAME_OUT).${NC}"
                echo "     Token may be missing Zone → DNS → Edit. Add the CNAME manually:"
                echo ""
                echo "       Type:    CNAME"
                echo "       Name:    $DOMAIN"
                echo "       Target:  $CNAME_TARGET"
                echo "       Proxy:   ON (orange cloud)"
                echo "     Body: ${CNAME_BODY:0:200}"
            fi
        else
            echo -e "${YELLOW}   ⚠ A different DNS record already exists for $DOMAIN.${NC}"
            echo "     Review and edit it in the dashboard:"
            echo "     https://dash.cloudflare.com/$ACCOUNT_ID/$APEX_TRY/dns/records"
        fi
    else
        echo ""
        echo -e "${YELLOW}⚠️  $DOMAIN is not in a Cloudflare zone on this account.${NC}"
        echo "   Add the CNAME at your existing DNS provider (Namecheap, OVH, Porkbun, …):"
        echo ""
        echo "       Type:    CNAME"
        echo "       Name:    $DOMAIN   (or '@' / 'www' depending on provider)"
        echo "       Target:  $CNAME_TARGET"
        echo ""
        echo "   Once that record exists, Cloudflare Pages auto-issues a TLS cert."
    fi
fi

echo ""
echo -e "${GREEN}🎉 Done.${NC}"
echo ""
echo "   Default URL:   https://$PROJECT_NAME.pages.dev"
echo "   Custom URL:    https://$DOMAIN"
echo "   Dashboard:     https://dash.cloudflare.com/$ACCOUNT_ID/pages/view/$PROJECT_NAME"
echo ""
