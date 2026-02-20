#!/bin/bash
set -e

# Benchmark GateFlow - load test + resource monitoring
# Usage: ./local/benchmark-gateflow.sh <url> <ssh_alias> [requests] [concurrency]
#
# Examples:
#   ./local/benchmark-gateflow.sh https://shop.example.com vps
#   ./local/benchmark-gateflow.sh https://shop.example.com vps 200 20

URL=${1}
SSH_ALIAS=${2}
REQUESTS=${3:-100}
CONCURRENT=${4:-10}

if [ -z "$URL" ] || [ -z "$SSH_ALIAS" ]; then
  echo "❌ Usage: $0 <url> <ssh_alias> [requests] [concurrency]"
  echo ""
  echo "Example:"
  echo "  $0 https://shop.example.com vps 200 20"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BENCHMARK_DIR="benchmark-$TIMESTAMP"

mkdir -p "$BENCHMARK_DIR"

echo "🎯 Benchmark GateFlow"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "URL:          $URL"
echo "SSH:          $SSH_ALIAS"
echo "Requests:     $REQUESTS"
echo "Concurrent:   $CONCURRENT"
echo "Output:       $BENCHMARK_DIR/"
echo ""

# Check if scripts exist
if [ ! -f "$SCRIPT_DIR/monitor-gateflow.sh" ]; then
  echo "❌ Not found: monitor-gateflow.sh"
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/load-test-gateflow.sh" ]; then
  echo "❌ Not found: load-test-gateflow.sh"
  exit 1
fi

# Estimate test duration
# Assume ~200ms per request + concurrency overhead
ESTIMATED_TIME=$(awk "BEGIN {printf \"%.0f\", ($REQUESTS / $CONCURRENT) * 0.2 + 10}")
MONITOR_TIME=$((ESTIMATED_TIME + 5))

echo "⏱️  Estimated time: ~${ESTIMATED_TIME}s"
echo ""
echo "🔍 BEFORE test - resource snapshot:"

# Snapshot before test
server_exec "pm2 list | grep gateflow" || true

# Get metrics via Python (compatible with macOS)
BEFORE=$(server_exec "pm2 jlist 2>/dev/null | python3 -c \"
import sys, json
try:
  data = json.load(sys.stdin)
  for proc in data:
    if 'gateflow' in proc.get('name', ''):
      print(json.dumps(proc))
      break
except:
  print('{}')
\"")

if [ -n "$BEFORE" ] && [ "$BEFORE" != "{}" ]; then
  BEFORE_CPU=$(echo "$BEFORE" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('monit', {}).get('cpu', 0))" 2>/dev/null || echo "0")
  BEFORE_MEM=$(echo "$BEFORE" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('monit', {}).get('memory', 0))" 2>/dev/null || echo "0")
  BEFORE_MEM_MB=$((BEFORE_MEM / 1024 / 1024))
else
  BEFORE_CPU=0
  BEFORE_MEM_MB=0
fi

echo "  CPU: ${BEFORE_CPU}%"
echo "  RAM: ${BEFORE_MEM_MB} MB"
echo ""

# Start monitoring in background
echo "📊 Starting monitoring (${MONITOR_TIME}s)..."
(
  cd "$SCRIPT_DIR"
  ./monitor-gateflow.sh "$SSH_ALIAS" "$MONITOR_TIME" > "../$BENCHMARK_DIR/monitoring.log" 2>&1
  mv gateflow-metrics-*.csv "../$BENCHMARK_DIR/" 2>/dev/null || true
) &
MONITOR_PID=$!

# Wait 3 seconds for monitoring to start
sleep 3

# Run load test
echo "🚀 Starting load test..."
echo ""

(
  cd "$SCRIPT_DIR"
  ./load-test-gateflow.sh "$URL" "$REQUESTS" "$CONCURRENT" > "../$BENCHMARK_DIR/load-test.log" 2>&1
) | tee "$BENCHMARK_DIR/load-test-output.txt"

echo ""
echo "⏳ Waiting for monitoring to finish..."
wait $MONITOR_PID

# Snapshot after test
echo ""
echo "🔍 AFTER test - resource snapshot:"

AFTER=$(server_exec "pm2 jlist 2>/dev/null | python3 -c \"
import sys, json
try:
  data = json.load(sys.stdin)
  for proc in data:
    if 'gateflow' in proc.get('name', ''):
      print(json.dumps(proc))
      break
except:
  print('{}')
\"")

if [ -n "$AFTER" ] && [ "$AFTER" != "{}" ]; then
  AFTER_CPU=$(echo "$AFTER" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('monit', {}).get('cpu', 0))" 2>/dev/null || echo "0")
  AFTER_MEM=$(echo "$AFTER" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('monit', {}).get('memory', 0))" 2>/dev/null || echo "0")
  AFTER_MEM_MB=$((AFTER_MEM / 1024 / 1024))
else
  AFTER_CPU=0
  AFTER_MEM_MB=0
fi

echo "  CPU: ${AFTER_CPU}%"
echo "  RAM: ${AFTER_MEM_MB} MB"
echo ""

# Generate report
REPORT_FILE="$BENCHMARK_DIR/REPORT.txt"

cat > "$REPORT_FILE" << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  BENCHMARK GATEFLOW - REPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Date:              $(date)
URL:               $URL
SSH Alias:         $SSH_ALIAS
Test Duration:     ${MONITOR_TIME}s
Total Requests:    $REQUESTS
Concurrent:        $CONCURRENT

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  RESOURCE USAGE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

BEFORE test:
  CPU: ${BEFORE_CPU}%
  RAM: ${BEFORE_MEM_MB} MB

AFTER test:
  CPU: ${AFTER_CPU}%
  RAM: ${AFTER_MEM_MB} MB

Change:
  CPU: $(python3 -c "print(round($AFTER_CPU - $BEFORE_CPU, 1))")%
  RAM: $((AFTER_MEM_MB - BEFORE_MEM_MB)) MB

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  OUTPUT FILES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. REPORT.txt              - this report
2. gateflow-metrics-*.csv  - detailed metrics (CSV)
3. load-test.log           - load test logs
4. monitoring.log          - monitoring logs

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PERFORMANCE ANALYSIS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

# Add test results to report
if [ -f "$BENCHMARK_DIR/load-test.log" ]; then
  echo "" >> "$REPORT_FILE"
  cat "$BENCHMARK_DIR/load-test.log" >> "$REPORT_FILE"
fi

# Add monitoring summary
if [ -f "$BENCHMARK_DIR/monitoring.log" ]; then
  echo "" >> "$REPORT_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$REPORT_FILE"
  echo "  MONITORING DETAILS" >> "$REPORT_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  tail -20 "$BENCHMARK_DIR/monitoring.log" >> "$REPORT_FILE"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Benchmark complete!"
echo ""
echo "📁 Results saved in: $BENCHMARK_DIR/"
echo ""
echo "📊 Files:"
echo "  - REPORT.txt              (summary)"
echo "  - gateflow-metrics-*.csv  (chart data)"
echo "  - load-test.log           (test details)"
echo ""
echo "💡 To view the report:"
echo "   cat $BENCHMARK_DIR/REPORT.txt"
echo ""
echo "📈 To create a chart:"
echo "   Open the CSV file in Excel/Google Sheets and create a line chart"
