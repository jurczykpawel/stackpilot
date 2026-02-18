#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/server-exec.sh"

# GateFlow resource usage monitoring
# Usage: ./local/monitor-gateflow.sh <ssh_alias> [duration_in_seconds] [app_name]
#
# Examples:
#   ./local/monitor-gateflow.sh vps                     # 60 seconds, gateflow-admin
#   ./local/monitor-gateflow.sh vps 300                  # 5 minutes
#   ./local/monitor-gateflow.sh vps 300 gateflow-shop    # specific instance

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ -z "${1:-}" ]; then
  echo "Usage: $0 <ssh_alias> [duration_in_seconds] [app_name]"
  echo ""
  echo "Examples:"
  echo "  $0 vps                     # 60 seconds, auto-detect"
  echo "  $0 vps 300                  # 5 minutes"
  echo "  $0 vps 300 gateflow-shop    # specific instance"
  exit 0
fi

SSH_ALIAS=${1}
DURATION=${2:-60}
APP_NAME=${3:-""}
INTERVAL=1

if [ -z "$APP_NAME" ]; then
  echo "🔍 Detecting GateFlow instances on server..."
  INSTANCES=$(server_exec "pm2 list | grep gateflow | awk '{print \$2}'")

  if [ -z "$INSTANCES" ]; then
    echo "❌ No GateFlow instances found"
    exit 1
  fi

  # If there's only one instance - use it
  COUNT=$(echo "$INSTANCES" | wc -l | xargs)
  if [ "$COUNT" -eq 1 ]; then
    APP_NAME="$INSTANCES"
    echo "✅ Found: $APP_NAME"
  else
    echo "Found instances:"
    echo "$INSTANCES" | nl
    echo ""
    read -p "Choose number (1-$COUNT): " choice
    APP_NAME=$(echo "$INSTANCES" | sed -n "${choice}p")
  fi
fi

OUTPUT_FILE="gateflow-metrics-$(date +%Y%m%d-%H%M%S).csv"

echo "📊 Monitoring: $APP_NAME"
echo "⏱️  Duration: ${DURATION}s (refresh every ${INTERVAL}s)"
echo "💾 Saving to: $OUTPUT_FILE"
echo ""
echo "timestamp,cpu_percent,memory_mb,memory_percent,uptime_min,restarts,status" > "$OUTPUT_FILE"

# Function to get metrics (compatible with macOS and Linux)
get_metrics() {
  server_exec "pm2 jlist 2>/dev/null | python3 -c \"
import sys, json
try:
  data = json.load(sys.stdin)
  for proc in data:
    if proc.get('name') == '$APP_NAME':
      print(json.dumps(proc))
      break
except:
  pass
\""
}

# Initial snapshot
echo "📸 Initial snapshot:"
INITIAL=$(get_metrics)

if [ -z "$INITIAL" ] || [ "$INITIAL" = "null" ]; then
  echo "❌ Cannot get metrics for: $APP_NAME"
  echo "   Check if PM2 is running: ssh $SSH_ALIAS 'pm2 list'"
  exit 1
fi

INITIAL_CPU=$(echo "$INITIAL" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('monit', {}).get('cpu', 0))")
INITIAL_MEM=$(echo "$INITIAL" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('monit', {}).get('memory', 0))")
INITIAL_MEM_MB=$((INITIAL_MEM / 1024 / 1024))
echo "   CPU: ${INITIAL_CPU}%"
echo "   RAM: ${INITIAL_MEM_MB} MB"
echo ""

# Monitoring loop
END_TIME=$(($(date +%s) + DURATION))
MAX_CPU=0
MAX_MEM=0
AVG_CPU_TOTAL=0
AVG_MEM_TOTAL=0
SAMPLES=0

while [ "$(date +%s)" -lt "$END_TIME" ]; do
  TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
  METRICS=$(get_metrics)

  if [ -z "$METRICS" ] || [ "$METRICS" = "null" ]; then
    echo "⚠️  Error fetching metrics, skipping sample..."
    sleep "$INTERVAL"
    continue
  fi

  # Parse JSON via Python
  CPU=$(echo "$METRICS" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('monit', {}).get('cpu', 0))")
  MEMORY=$(echo "$METRICS" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('monit', {}).get('memory', 0))")
  MEMORY_MB=$((MEMORY / 1024 / 1024))
  UPTIME_MS=$(echo "$METRICS" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('pm2_env', {}).get('pm_uptime', 0))")
  UPTIME_MIN=$((UPTIME_MS / 1000 / 60))
  RESTARTS=$(echo "$METRICS" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('pm2_env', {}).get('restart_time', 0))")
  STATUS=$(echo "$METRICS" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('pm2_env', {}).get('status', 'unknown'))")

  # Calculate memory percentage (assuming ~1GB RAM available for app)
  MEMORY_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($MEMORY_MB / 1024) * 100}")

  # Save to CSV
  echo "$TIMESTAMP,$CPU,$MEMORY_MB,$MEMORY_PERCENT,$UPTIME_MIN,$RESTARTS,$STATUS" >> "$OUTPUT_FILE"

  # Update statistics
  MAX_CPU=$(python3 -c "print(max($MAX_CPU, $CPU))")
  if [ "$MEMORY_MB" -gt "$MAX_MEM" ]; then MAX_MEM=$MEMORY_MB; fi

  AVG_CPU_TOTAL=$(python3 -c "print($AVG_CPU_TOTAL + $CPU)")
  AVG_MEM_TOTAL=$((AVG_MEM_TOTAL + MEMORY_MB))
  SAMPLES=$((SAMPLES + 1))

  # Progress bar
  ELAPSED=$(($(date +%s) - (END_TIME - DURATION)))
  PROGRESS=$((ELAPSED * 100 / DURATION))
  printf "\r⏳ [%-50s] %d%% | CPU: %4.1f%% | RAM: %4d MB | Uptime: %dm" \
    "$(printf '#%.0s' $(seq 1 $((PROGRESS / 2))))" \
    "$PROGRESS" "$CPU" "$MEMORY_MB" "$UPTIME_MIN"

  sleep "$INTERVAL"
done

# Calculate averages
if [ "$SAMPLES" -gt 0 ]; then
  AVG_CPU=$(python3 -c "print(round($AVG_CPU_TOTAL / $SAMPLES, 1))")
  AVG_MEM=$((AVG_MEM_TOTAL / SAMPLES))
else
  AVG_CPU=0
  AVG_MEM=0
fi

echo ""
echo ""
echo "📈 Summary ($SAMPLES samples):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CPU:"
echo "  Max:     ${MAX_CPU}%"
echo "  Average: ${AVG_CPU}%"
echo ""
echo "RAM:"
echo "  Max:     ${MAX_MEM} MB"
echo "  Average: ${AVG_MEM} MB"
echo ""

# Analysis for a VPS with 1GB RAM
if [ "$MAX_MEM" -lt 500 ]; then
  echo "✅ RAM usage: Excellent! The application fits on a VPS with 1GB RAM"
elif [ "$MAX_MEM" -lt 700 ]; then
  echo "⚠️  RAM usage: Acceptable, but monitor under higher load"
else
  echo "🔥 RAM usage: High! Consider a VPS with 2GB RAM or optimization"
fi

echo ""
echo "💾 Detailed data: $OUTPUT_FILE"
echo ""
echo "📊 To visualize in Excel/Google Sheets:"
echo "   1. Open $OUTPUT_FILE"
echo "   2. Create a chart from columns: timestamp, cpu_percent, memory_mb"
