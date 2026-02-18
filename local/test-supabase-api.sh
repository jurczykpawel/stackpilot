#!/bin/bash

# Test fetching Supabase keys via API
# Checks if ?reveal=true works for new projects

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}🧪 Test fetching Supabase keys via API${NC}"
echo ""
echo "This test checks if automatic key fetching works with new Supabase projects."
echo ""

# Load functions from lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

source "$LIB_DIR/gateflow-setup.sh"

# Check if we have a token
if [ ! -f ~/.config/supabase/access_token ]; then
    echo -e "${RED}❌ Missing Supabase token${NC}"
    echo ""
    echo "You need to log in first:"
    echo "   ./local/setup-gateflow-config.sh"
    echo ""
    exit 1
fi

SUPABASE_TOKEN=$(cat ~/.config/supabase/access_token)

# Fetch project list
echo "🔍 Fetching your Supabase projects..."
echo ""

PROJECTS=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" "https://api.supabase.com/v1/projects")

if ! echo "$PROJECTS" | grep -q '"id"'; then
    echo -e "${RED}❌ Failed to fetch projects${NC}"
    echo "   Check if the token is current"
    exit 1
fi

# Display projects
PROJECT_COUNT=$(echo "$PROJECTS" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")

echo "Found projects: $PROJECT_COUNT"
echo ""

if [ "$PROJECT_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}You don't have any projects yet.${NC}"
    echo "Create a project: https://supabase.com/dashboard"
    exit 0
fi

# Display projects for selection
echo "Choose a project to test:"
echo ""

COUNTER=1
declare -a PROJECT_REFS

echo "$PROJECTS" | python3 -c "
import sys, json
for proj in json.load(sys.stdin):
    print(f'{proj.get(\"name\", \"N/A\")} ({proj.get(\"id\", \"N/A\")})')
" | while read -r line; do
    echo "  $COUNTER) $line"
    COUNTER=$((COUNTER + 1))
done

# Save refs to array
while IFS= read -r ref; do
    PROJECT_REFS+=("$ref")
done < <(echo "$PROJECTS" | python3 -c "import sys, json; [print(p['id']) for p in json.load(sys.stdin)]")

echo ""
read -p "Choose number [1-$PROJECT_COUNT]: " CHOICE

if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$PROJECT_COUNT" ]; then
    echo -e "${RED}❌ Invalid choice${NC}"
    exit 1
fi

# Get selected ref (Python counts from 0)
PROJECT_REF=$(echo "$PROJECTS" | python3 -c "import sys, json; print(json.load(sys.stdin)[$((CHOICE - 1))]['id'])")

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🔑 TEST: Fetching keys for project $PROJECT_REF"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Test 1: WITHOUT reveal parameter
echo "📋 Test 1: Fetching WITHOUT ?reveal parameter (old method)"
echo ""

API_KEYS_NO_REVEAL=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" \
    "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys")

# Check if masked
SECRET_KEY_NO_REVEAL=$(echo "$API_KEYS_NO_REVEAL" | python3 -c "
import sys, json
try:
    for key in json.load(sys.stdin):
        if key.get('type') == 'secret':
            print(key.get('api_key', ''))
            break
except:
    pass
")

if [[ "$SECRET_KEY_NO_REVEAL" =~ ··· ]]; then
    echo -e "${YELLOW}   ⚠️  Secret key is MASKED (expected)${NC}"
    echo "      $SECRET_KEY_NO_REVEAL"
else
    echo -e "${GREEN}   ✓ Secret key is full (legacy project)${NC}"
    echo "      ${SECRET_KEY_NO_REVEAL:0:30}..."
fi

echo ""

# Test 2: WITH reveal parameter
echo "📋 Test 2: Fetching WITH ?reveal=true parameter (new method)"
echo ""

API_KEYS_WITH_REVEAL=$(curl -s -H "Authorization: Bearer $SUPABASE_TOKEN" \
    "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys?reveal=true")

# Check if full
SECRET_KEY_WITH_REVEAL=$(echo "$API_KEYS_WITH_REVEAL" | python3 -c "
import sys, json
try:
    for key in json.load(sys.stdin):
        if key.get('type') == 'secret':
            print(key.get('api_key', ''))
            break
except:
    pass
")

if [[ "$SECRET_KEY_WITH_REVEAL" =~ ··· ]]; then
    echo -e "${RED}   ❌ Secret key STILL masked (problem!)${NC}"
    echo "      $SECRET_KEY_WITH_REVEAL"
    echo ""
    echo "The token may not have permissions for 'reveal'?"
else
    echo -e "${GREEN}   ✅ Secret key is FULL!${NC}"
    echo "      ${SECRET_KEY_WITH_REVEAL:0:30}..."
fi

echo ""

# Summary
echo "════════════════════════════════════════════════════════════════"
echo "📊 SUMMARY"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [[ "$SECRET_KEY_NO_REVEAL" =~ ··· ]] && [[ ! "$SECRET_KEY_WITH_REVEAL" =~ ··· ]]; then
    echo -e "${GREEN}✅ SUCCESS! The ?reveal=true parameter works correctly!${NC}"
    echo ""
    echo "   WITHOUT reveal: masked (old endpoint)"
    echo "   WITH reveal:    full key ✓"
    echo ""
    echo "Deploy.sh will work automatically with new projects! 🎉"
elif [[ ! "$SECRET_KEY_NO_REVEAL" =~ ··· ]]; then
    echo -e "${BLUE}ℹ️  This is a legacy project${NC}"
    echo ""
    echo "   Legacy projects return full keys even without ?reveal=true"
    echo "   Deploy.sh will work correctly."
else
    echo -e "${YELLOW}⚠️  Both endpoints return masked keys${NC}"
    echo ""
    echo "Possible causes:"
    echo "   • Token does not have permissions for 'reveal'"
    echo "   • New project requires different permissions"
    echo ""
    echo "Contact Supabase support."
fi

echo ""
