#!/bin/bash
set -e

# GateFlow Load Test
# Requires: curl, jq (optional)
#
# Usage: ./local/load-test-gateflow.sh <url> [num_requests] [concurrency]
#
# Examples:
#   ./local/load-test-gateflow.sh https://shop.example.com
#   ./local/load-test-gateflow.sh https://shop.example.com 100 10
#   ./local/load-test-gateflow.sh https://shop.example.com 500 20

URL=${1}
TOTAL_REQUESTS=${2:-50}
CONCURRENT=${3:-5}

if [ -z "$URL" ]; then
  echo "❌ Usage: $0 <url> [num_requests] [concurrency]"
  exit 1
fi

# Remove trailing slash
URL=${URL%/}

echo "🚀 GateFlow Load Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "URL:          $URL"
echo "Requests:     $TOTAL_REQUESTS"
echo "Concurrent:   $CONCURRENT"
echo ""
echo "📝 Test scenario:"
echo "  1. Home page (20%)"
echo "  2. Product list (30%)"
echo "  3. Product details (30%)"
echo "  4. User profile (20%)"
echo ""

# Check if server responds
echo "🔍 Checking server availability..."
if ! curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$URL" > /dev/null; then
  echo "❌ Server not responding. Check if the application is running."
  exit 1
fi
echo "✅ Server available"
echo ""

# Prepare file with URLs to test
TEST_FILE=$(mktemp)
DETAILS_LOG="/tmp/load-test-details-$(date +%s).log"
trap "rm -f $TEST_FILE; echo '💡 Details: $DETAILS_LOG'" EXIT

# Generate requests (scenario proportions)
HOME_REQUESTS=$((TOTAL_REQUESTS * 20 / 100))
PRODUCTS_REQUESTS=$((TOTAL_REQUESTS * 30 / 100))
PRODUCT_DETAILS_REQUESTS=$((TOTAL_REQUESTS * 30 / 100))
PROFILE_REQUESTS=$((TOTAL_REQUESTS - HOME_REQUESTS - PRODUCTS_REQUESTS - PRODUCT_DETAILS_REQUESTS))

for i in $(seq 1 $HOME_REQUESTS); do echo "$URL"; done >> "$TEST_FILE"
for i in $(seq 1 $PRODUCTS_REQUESTS); do echo "$URL/products"; done >> "$TEST_FILE"
for i in $(seq 1 $PRODUCT_DETAILS_REQUESTS); do echo "$URL/products/demo-product-$((RANDOM % 5))"; done >> "$TEST_FILE"
for i in $(seq 1 $PROFILE_REQUESTS); do echo "$URL/profile"; done >> "$TEST_FILE"

# Shuffle requests
sort -R "$TEST_FILE" -o "$TEST_FILE"

echo "🔥 Starting test..."
echo ""

START_TIME=$(date +%s)
SUCCESS=0
FAILED=0
TOTAL_TIME=0
MIN_TIME=99999
MAX_TIME=0

# Function to send a request
send_request() {
  local url=$1

  # macOS and Linux compatibility - use python3 for milliseconds
  local start=$(python3 -c 'import time; print(int(time.time() * 1000))')
  local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "$url" 2>/dev/null || echo "000")
  local end=$(python3 -c 'import time; print(int(time.time() * 1000))')
  local duration=$((end - start))

  # Log details (URL, HTTP code, time)
  echo "$url|$http_code|$duration" >> "$DETAILS_LOG"

  echo "$http_code $duration"
}

export -f send_request
export URL DETAILS_LOG

# Execute tests concurrently
cat "$TEST_FILE" | xargs -P "$CONCURRENT" -I {} bash -c 'send_request "{}"' | while read -r code duration; do
  if [ "$code" = "200" ] || [ "$code" = "304" ]; then
    SUCCESS=$((SUCCESS + 1))
  else
    FAILED=$((FAILED + 1))
  fi

  TOTAL_TIME=$((TOTAL_TIME + duration))

  if [ "$duration" -lt "$MIN_TIME" ]; then MIN_TIME=$duration; fi
  if [ "$duration" -gt "$MAX_TIME" ]; then MAX_TIME=$duration; fi

  # Progress
  COMPLETED=$((SUCCESS + FAILED))
  PROGRESS=$((COMPLETED * 100 / TOTAL_REQUESTS))
  printf "\r⏳ [%-50s] %d%% | ✅ %d | ❌ %d" \
    "$(printf '#%.0s' $(seq 1 $((PROGRESS / 2))))" \
    "$PROGRESS" "$SUCCESS" "$FAILED"
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Read final statistics from DETAILS_LOG (pipe-subshell loses variables)
SUCCESS=0
FAILED=0
AVG_TIME=0
MIN_TIME=99999
MAX_TIME=0
if [ -f "$DETAILS_LOG" ]; then
  SUCCESS=$(grep -c '|200\||304|' "$DETAILS_LOG" 2>/dev/null || true)
  SUCCESS=${SUCCESS:-0}
  FAILED=$((TOTAL_REQUESTS - SUCCESS))
  if [ "$SUCCESS" -gt 0 ]; then
    TOTAL_TIME=$(awk -F'|' '{sum+=$3} END {print int(sum)}' "$DETAILS_LOG")
    AVG_TIME=$((TOTAL_TIME / TOTAL_REQUESTS))
    MIN_TIME=$(awk -F'|' '{print $3}' "$DETAILS_LOG" | sort -n | head -1)
    MAX_TIME=$(awk -F'|' '{print $3}' "$DETAILS_LOG" | sort -n | tail -1)
  fi
fi

echo ""
echo ""
echo "📈 Test results:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Duration:         ${DURATION}s"
echo "Requests:"
echo "  Success:        $SUCCESS"
echo "  Errors:         $FAILED"
echo "  Success rate:   $((SUCCESS * 100 / TOTAL_REQUESTS))%"
echo ""
echo "Response times:"
if [ "$MIN_TIME" -eq 99999 ]; then
  echo "  Min:            -"
else
  echo "  Min:            ${MIN_TIME}ms"
fi
echo "  Average:        ${AVG_TIME}ms"
echo "  Max:            ${MAX_TIME}ms"
echo ""

# Per-endpoint statistics
echo "🔍 Per-endpoint statistics:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f "$DETAILS_LOG" ]; then
  # Helper function: count lines matching a pattern
  count_lines() { grep -cE "$1" "$DETAILS_LOG" 2>/dev/null || true; }

  # Home (exact URL match without subpath)
  HOME_TOTAL=$(count_lines "^${URL}\|[0-9]")
  HOME_SUCCESS=$(count_lines "^${URL}\|(200|304)\|")
  HOME_FAILED=$((HOME_TOTAL - HOME_SUCCESS))
  HOME_404=$(count_lines "^${URL}\|404\|")
  HOME_AVG=$(grep -E "^${URL}\|[0-9]" "$DETAILS_LOG" 2>/dev/null | awk -F'|' '{sum+=$3} END {if(NR>0) printf "%.0f", sum/NR; else print "-"}')

  # Products
  PRODUCTS_TOTAL=$(count_lines "^${URL}/products\|[0-9]")
  PRODUCTS_SUCCESS=$(count_lines "^${URL}/products\|(200|304)\|")
  PRODUCTS_FAILED=$((PRODUCTS_TOTAL - PRODUCTS_SUCCESS))
  PRODUCTS_AVG=$(grep -E "^${URL}/products\|[0-9]" "$DETAILS_LOG" 2>/dev/null | awk -F'|' '{sum+=$3} END {if(NR>0) printf "%.0f", sum/NR; else print "-"}')

  # Product Details (aggregate all demo-product-X)
  DETAILS_TOTAL=$(count_lines "^${URL}/products/demo-product-")
  DETAILS_SUCCESS=$(count_lines "^${URL}/products/demo-product-[0-9]+\|(200|304)\|")
  DETAILS_FAILED=$((DETAILS_TOTAL - DETAILS_SUCCESS))
  DETAILS_404=$(count_lines "^${URL}/products/demo-product-[0-9]+\|404\|")
  DETAILS_AVG=$(grep -E "^${URL}/products/demo-product-" "$DETAILS_LOG" 2>/dev/null | awk -F'|' '{sum+=$3} END {if(NR>0) printf "%.0f", sum/NR; else print "-"}')

  # Profile
  PROFILE_TOTAL=$(count_lines "^${URL}/profile\|[0-9]")
  PROFILE_SUCCESS=$(count_lines "^${URL}/profile\|(200|304)\|")
  PROFILE_FAILED=$((PROFILE_TOTAL - PROFILE_SUCCESS))
  PROFILE_AVG=$(grep -E "^${URL}/profile\|[0-9]" "$DETAILS_LOG" 2>/dev/null | awk -F'|' '{sum+=$3} END {if(NR>0) printf "%.0f", sum/NR; else print "-"}')

  # Display table
  printf "%-20s %10s %10s %10s %10s\n" "Endpoint" "Total" "Success" "Failed" "Avg(ms)"
  printf "%-20s %10s %10s %10s %10s\n" "--------" "-----" "-------" "------" "-------"
  printf "%-20s %10d %10d %10d %10s\n" "Home" "$HOME_TOTAL" "$HOME_SUCCESS" "$HOME_FAILED" "${HOME_AVG:--}"
  printf "%-20s %10d %10d %10d %10s\n" "Products" "$PRODUCTS_TOTAL" "$PRODUCTS_SUCCESS" "$PRODUCTS_FAILED" "${PRODUCTS_AVG:--}"
  printf "%-20s %10d %10d %10d %10s\n" "Product Details" "$DETAILS_TOTAL" "$DETAILS_SUCCESS" "$DETAILS_FAILED" "${DETAILS_AVG:--}"
  printf "%-20s %10d %10d %10d %10s\n" "Profile" "$PROFILE_TOTAL" "$PROFILE_SUCCESS" "$PROFILE_FAILED" "${PROFILE_AVG:--}"

  # Error details
  if [ "$DETAILS_404" -gt 0 ] || [ "$HOME_404" -gt 0 ]; then
    echo ""
    echo "⚠️  404 errors:"
    if [ "$DETAILS_404" -gt 0 ]; then
      echo "  - Product Details: $DETAILS_404 requests returned 404 (demo-product-X does not exist)"
    fi
    if [ "$HOME_404" -gt 0 ]; then
      echo "  - Home: $HOME_404 requests returned 404"
    fi
  fi

  # Error codes
  echo ""
  echo "📋 Error codes:"
  grep -vE '\|(200|304)\|' "$DETAILS_LOG" 2>/dev/null | \
    awk -F'|' '{codes[$2]++} END {for (c in codes) printf "  %s: %d\n", c, codes[c]}' | sort -k2 -rn || echo "  No errors"

  # Sample failed requests
  ERRORS=$(grep -vE '\|(200|304)\|' "$DETAILS_LOG" 2>/dev/null | head -5 || true)
  if [ -n "$ERRORS" ]; then
    echo ""
    echo "❌ Sample failed requests:"
    echo "$ERRORS" | while IFS='|' read -r url code duration; do
      printf "  %s -> %s (%sms)\n" "$url" "$code" "$duration"
    done
  fi

  echo ""
  echo "💡 Details saved in: $DETAILS_LOG"
else
  echo "  No details to analyze"
fi

echo ""

# Performance rating
if [ "$AVG_TIME" -lt 500 ]; then
  echo "✅ Performance: Excellent! (< 500ms)"
elif [ "$AVG_TIME" -lt 1000 ]; then
  echo "⚠️  Performance: Good, but could be optimized (500-1000ms)"
elif [ "$AVG_TIME" -lt 2000 ]; then
  echo "🔶 Performance: Average, needs optimization (1-2s)"
else
  echo "🔥 Performance: Poor! Urgent optimization needed (> 2s)"
fi

echo ""
echo "💡 Tips:"
echo "  - Run ./local/monitor-gateflow.sh during the test to see resource usage"
echo "  - Increase concurrency (--concurrent) to simulate more users"
echo "  - Check logs: ssh <alias> 'pm2 logs gateflow-admin --lines 100'"
