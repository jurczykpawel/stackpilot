#!/bin/bash

# StackPilot - Cloudflare Pages credentials wizard
#
# Interactive setup for `./local/deploy-static-cf.sh`.
# Prompts for a Cloudflare API token (Pages:Edit scope) and your Account ID,
# verifies both against the live API, and saves them to your chosen location.
#
# Author: Pawel (Lazy Engineer)

set -e

# Help flag handler — surfaces what the wizard does without running it.
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<EOF
Usage: $0

Interactive credentials wizard for ./local/deploy-static-cf.sh (Cloudflare Pages).

What it does:
  1. Opens https://dash.cloudflare.com/profile/api-tokens with a preset
     scope template (Account → Cloudflare Pages → Edit).
  2. Reads your token (hidden input) and verifies it against the CF API.
  3. Auto-detects your Account ID when the token has Account:Read;
     otherwise prompts you for it and validates the format.
  4. Probes Pages:Edit permission to confirm the token actually works.
  5. Saves credentials where you choose:
       a) shell rc (persistent, recommended)
       b) ~/.config/cloudflare/config
       c) print-only (you copy & paste into your shell)

Re-running with existing working credentials is a no-op — the wizard
detects, verifies, and exits without prompting.

Full reference: docs/cloudflare-pages-deploy.md
EOF
    exit 0
fi

# Colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

CONFIG_DIR="$HOME/.config/cloudflare"
CONFIG_FILE="$CONFIG_DIR/config"
CF_API="https://api.cloudflare.com/client/v4"
TOKEN_URL_TEMPLATE="https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22pages_edit%22%2C%22type%22%3A%22account%22%7D%5D&name=stackpilot-pages"

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  StackPilot — Cloudflare Pages credentials setup${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "This wizard configures the credentials used by:"
echo -e "  ${GREEN}./local/deploy-static-cf.sh${NC}"
echo ""
echo "You'll need:"
echo "  1. A Cloudflare API token with scope: Account → Cloudflare Pages → Edit"
echo "  2. Your Cloudflare Account ID"
echo ""

# ---------------------------------------------------------------------------
# Detect existing credentials and offer to skip
# ---------------------------------------------------------------------------

EXISTING_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
EXISTING_ACCOUNT="${CLOUDFLARE_ACCOUNT_ID:-}"
if [ -z "$EXISTING_TOKEN" ] && [ -f "$CONFIG_FILE" ]; then
    EXISTING_TOKEN="$(grep '^API_TOKEN=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
fi
if [ -z "$EXISTING_ACCOUNT" ] && [ -f "$CONFIG_FILE" ]; then
    EXISTING_ACCOUNT="$(grep '^ACCOUNT_ID=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
fi

if [ -n "$EXISTING_TOKEN" ] && [ -n "$EXISTING_ACCOUNT" ]; then
    echo -e "${YELLOW}Existing credentials detected.${NC}"
    echo "  API_TOKEN:  set (length ${#EXISTING_TOKEN})"
    echo "  ACCOUNT_ID: ${EXISTING_ACCOUNT:0:8}..."
    echo ""
    echo "Verifying existing credentials against Cloudflare..."
    PROBE=$(curl -sS -o /dev/null -w "%{http_code}" \
        "$CF_API/accounts/$EXISTING_ACCOUNT/pages/projects?per_page=1" \
        -H "Authorization: Bearer $EXISTING_TOKEN")
    if [ "$PROBE" = "200" ]; then
        echo -e "${GREEN}✓ Existing credentials already work for Cloudflare Pages.${NC}"
        echo ""
        echo "Nothing to do. To re-configure anyway, delete the existing entry first:"
        echo "  unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID"
        echo "  sed -i.bak '/^API_TOKEN=/d;/^ACCOUNT_ID=/d' $CONFIG_FILE"
        echo "  $0"
        exit 0
    fi
    echo -e "${YELLOW}⚠ Existing credentials do not have Pages:Edit. Re-configuring.${NC}"
    echo ""
fi

# ---------------------------------------------------------------------------
# Step 1 — Open browser at the token creation page
# ---------------------------------------------------------------------------

echo -e "${YELLOW}Step 1.${NC} Opening Cloudflare token creation page..."
echo ""
echo "On the page, set:"
echo "  Name:        stackpilot-pages"
echo "  Permissions: Account → Cloudflare Pages → Edit"
echo "               User    → User Details     → Read   (auto-added)"
echo "               Zone    → DNS              → Edit   (optional — only if"
echo "                                                    you want auto custom-domain CNAME)"
echo "  Resources:   Account → Include → All accounts (or specific)"
echo ""
echo "Click: Continue → Create Token → COPY the token."
echo ""

if command -v open >/dev/null 2>&1; then
    open "$TOKEN_URL_TEMPLATE" 2>/dev/null || true
elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$TOKEN_URL_TEMPLATE" 2>/dev/null || true
elif command -v start >/dev/null 2>&1; then
    start "$TOKEN_URL_TEMPLATE" 2>/dev/null || true
else
    echo "  (Couldn't auto-open a browser. Open this URL manually:)"
    echo "  $TOKEN_URL_TEMPLATE"
fi

read -r -p "Press Enter once you've copied the token to the clipboard..."
echo ""

# ---------------------------------------------------------------------------
# Step 2 — Read token (hidden)
# ---------------------------------------------------------------------------

read -r -s -p "Paste your Cloudflare API token: " API_TOKEN
echo ""
if [ -z "$API_TOKEN" ]; then
    echo -e "${RED}✗ No token provided. Aborting.${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3 — Verify token
# ---------------------------------------------------------------------------

echo ""
echo -e "${BLUE}Verifying token...${NC}"
VERIFY=$(curl -fsS "$CF_API/user/tokens/verify" \
    -H "Authorization: Bearer $API_TOKEN" 2>/dev/null) || {
    echo -e "${RED}✗ Network error or invalid token.${NC}"
    exit 1
}
if ! echo "$VERIFY" | grep -q '"success":true'; then
    echo -e "${RED}✗ Cloudflare rejected the token. Make sure you copied it fully.${NC}"
    exit 1
fi
echo -e "${GREEN}  ✓ Token is valid${NC}"

# ---------------------------------------------------------------------------
# Step 4 — Resolve Account ID (auto-fetch if possible, else prompt)
# ---------------------------------------------------------------------------

ACCOUNT_ID=""
echo ""
echo -e "${BLUE}Resolving Account ID...${NC}"

ACCOUNTS_JSON=$(curl -fsS "$CF_API/accounts" \
    -H "Authorization: Bearer $API_TOKEN" 2>/dev/null) || ACCOUNTS_JSON=""

if [ -n "$ACCOUNTS_JSON" ] && echo "$ACCOUNTS_JSON" | grep -q '"success":true'; then
    if command -v jq >/dev/null 2>&1; then
        ACCOUNT_PAIRS=$(echo "$ACCOUNTS_JSON" | jq -r '.result[] | "\(.id)\t\(.name)"' 2>/dev/null)
    else
        ACCOUNT_PAIRS=$(echo "$ACCOUNTS_JSON" \
            | tr '{' '\n' | grep '"name"' \
            | sed -E 's/.*"id":"([a-f0-9]+)".*"name":"([^"]+)".*/\1\t\2/' \
            | grep -E '^[a-f0-9]{32}\t')
    fi
    ACCOUNT_COUNT=$(echo "$ACCOUNT_PAIRS" | grep -c . || true)

    if [ "$ACCOUNT_COUNT" -eq 1 ]; then
        ACCOUNT_ID=$(echo "$ACCOUNT_PAIRS" | head -1 | cut -f1)
        ACCOUNT_NAME=$(echo "$ACCOUNT_PAIRS" | head -1 | cut -f2)
        echo -e "${GREEN}  ✓ Auto-detected: $ACCOUNT_NAME (${ACCOUNT_ID:0:8}...)${NC}"
    elif [ "$ACCOUNT_COUNT" -gt 1 ]; then
        echo "  You have multiple Cloudflare accounts. Pick one:"
        echo ""
        i=1
        while IFS=$'\t' read -r id name; do
            printf "  %d) %-40s %s\n" "$i" "$name" "${id:0:8}..."
            i=$((i+1))
        done <<< "$ACCOUNT_PAIRS"
        echo ""
        read -r -p "Enter number: " choice
        ACCOUNT_ID=$(echo "$ACCOUNT_PAIRS" | sed -n "${choice}p" | cut -f1)
        if [ -z "$ACCOUNT_ID" ]; then
            echo -e "${RED}✗ Invalid choice.${NC}"
            exit 1
        fi
    fi
fi

if [ -z "$ACCOUNT_ID" ]; then
    echo "  Token doesn't have Account:Read permission, so I can't auto-fetch."
    echo "  Find it manually:"
    echo "    1. Open https://dash.cloudflare.com"
    echo "    2. Click any domain (or stay on overview)"
    echo "    3. Copy 'Account ID' from the right sidebar"
    echo ""
    read -r -p "Paste your Account ID: " ACCOUNT_ID
    if ! [[ "$ACCOUNT_ID" =~ ^[a-f0-9]{32}$ ]]; then
        echo -e "${RED}✗ Account ID must be 32 hex characters. Got: '$ACCOUNT_ID'${NC}"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 5 — Verify Pages:Edit on this Account
# ---------------------------------------------------------------------------

echo ""
echo -e "${BLUE}Verifying Pages:Edit permission...${NC}"
PROBE=$(curl -sS -o /tmp/sp-cf-setup.$$.json -w "%{http_code}" \
    "$CF_API/accounts/$ACCOUNT_ID/pages/projects?per_page=1" \
    -H "Authorization: Bearer $API_TOKEN")
PROBE_BODY="$(cat /tmp/sp-cf-setup.$$.json 2>/dev/null)"
rm -f /tmp/sp-cf-setup.$$.json

if [ "$PROBE" = "200" ]; then
    echo -e "${GREEN}  ✓ Pages:Edit confirmed${NC}"
elif [ "$PROBE" = "404" ]; then
    echo -e "${RED}✗ Account ID '$ACCOUNT_ID' not found in this token's scope.${NC}"
    exit 1
else
    case "$PROBE_BODY" in
        *"Authentication error"*|*"authentication_error"*|*"code\":9109"*|*"code\":10000"*)
            echo -e "${RED}✗ Token lacks 'Account → Cloudflare Pages → Edit' permission.${NC}"
            echo "   Go back to Step 1 and check the scope. Re-run this wizard."
            ;;
        *)
            echo -e "${RED}✗ Unexpected error (HTTP $PROBE).${NC}"
            echo "   Body: ${PROBE_BODY:0:200}"
            ;;
    esac
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6 — Save (let user choose)
# ---------------------------------------------------------------------------

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "Where do you want to save these credentials?"
echo ""
echo "  1) Shell rc file (persistent across terminals — RECOMMENDED)"
echo "     Adds 'export CLOUDFLARE_*' lines to ~/.zshenv or ~/.bashrc."
echo ""
echo "  2) StackPilot config file: $CONFIG_FILE"
echo "     Stored as API_TOKEN= and ACCOUNT_ID= (chmod 600)."
echo ""
echo "  3) Just print them — I'll set the env vars myself."
echo ""
read -r -p "Choice [1/2/3]: " choice

case "$choice" in
    1)
        if [ -f "$HOME/.zshenv" ] || [ -n "${ZSH_VERSION:-}" ]; then
            RC_FILE="$HOME/.zshenv"
        elif [ -f "$HOME/.bashrc" ] || [ -n "${BASH_VERSION:-}" ]; then
            RC_FILE="$HOME/.bashrc"
        else
            RC_FILE="$HOME/.profile"
        fi
        read -r -p "Append to $RC_FILE? [y/N]: " confirm
        if [[ "$confirm" =~ ^[YyTt]$ ]]; then
            {
                echo ""
                echo "# StackPilot — Cloudflare Pages (added $(date +%Y-%m-%d))"
                echo "export CLOUDFLARE_API_TOKEN='$API_TOKEN'"
                echo "export CLOUDFLARE_ACCOUNT_ID='$ACCOUNT_ID'"
            } >> "$RC_FILE"
            echo -e "${GREEN}✓ Appended to $RC_FILE${NC}"
            echo ""
            echo "Activate now: source $RC_FILE"
        else
            echo "Aborted save."
            exit 1
        fi
        ;;
    2)
        mkdir -p "$CONFIG_DIR"
        chmod 700 "$CONFIG_DIR"
        touch "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        # Replace existing API_TOKEN / ACCOUNT_ID lines or append if missing.
        TMP="$CONFIG_FILE.tmp.$$"
        {
            grep -v -E '^(API_TOKEN|ACCOUNT_ID)=' "$CONFIG_FILE" 2>/dev/null || true
            echo "API_TOKEN=$API_TOKEN"
            echo "ACCOUNT_ID=$ACCOUNT_ID"
        } > "$TMP"
        mv "$TMP" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        echo -e "${GREEN}✓ Saved to $CONFIG_FILE${NC}"
        ;;
    3)
        echo ""
        echo "Run these in your current shell:"
        echo ""
        echo "  export CLOUDFLARE_API_TOKEN='$API_TOKEN'"
        echo "  export CLOUDFLARE_ACCOUNT_ID='$ACCOUNT_ID'"
        echo ""
        echo "Not persisted. They will disappear when this shell exits."
        ;;
    *)
        echo "Invalid choice."
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}🎉 Setup complete.${NC}"
echo ""
echo "Next step — deploy a static site:"
echo "  cd your-site"
echo "  ./local/deploy-static-cf.sh your-domain.com"
echo ""
