#!/bin/bash
set -e

# Benchmark GateFlow - test obciążeniowy + monitorowanie zasobów
# Użycie: ./local/benchmark-gateflow.sh <url> <ssh_alias> [requesty] [współbieżność]
#
# Przykłady:
#   ./local/benchmark-gateflow.sh https://shop.byst.re mikrus
#   ./local/benchmark-gateflow.sh https://shop.example.com mikrus 200 20

URL=${1}
SSH_ALIAS=${2}
REQUESTS=${3:-100}
CONCURRENT=${4:-10}

if [ -z "$URL" ] || [ -z "$SSH_ALIAS" ]; then
  echo "❌ Użycie: $0 <url> <ssh_alias> [requesty] [współbieżność]"
  echo ""
  echo "Przykład:"
  echo "  $0 https://shop.byst.re mikrus 200 20"
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
echo "Requesty:     $REQUESTS"
echo "Współbieżne:  $CONCURRENT"
echo "Output:       $BENCHMARK_DIR/"
echo ""

# Sprawdź czy skrypty istnieją
if [ ! -f "$SCRIPT_DIR/monitor-gateflow.sh" ]; then
  echo "❌ Nie znaleziono: monitor-gateflow.sh"
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/load-test-gateflow.sh" ]; then
  echo "❌ Nie znaleziono: load-test-gateflow.sh"
  exit 1
fi

# Szacuj czas trwania testu
# Zakładamy ~200ms na request + overhead współbieżności
ESTIMATED_TIME=$(awk "BEGIN {printf \"%.0f\", ($REQUESTS / $CONCURRENT) * 0.2 + 10}")
MONITOR_TIME=$((ESTIMATED_TIME + 5))

echo "⏱️  Szacowany czas: ~${ESTIMATED_TIME}s"
echo ""
echo "🔍 PRZED testem - snapshot zasobów:"

# Snapshot przed testem
server_exec "pm2 list | grep gateflow" || true

# Pobierz metryki przez Python (kompatybilne z macOS)
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

# Uruchom monitoring w tle
echo "📊 Uruchamiam monitoring (${MONITOR_TIME}s)..."
(
  cd "$SCRIPT_DIR"
  ./monitor-gateflow.sh "$SSH_ALIAS" "$MONITOR_TIME" > "../$BENCHMARK_DIR/monitoring.log" 2>&1
  mv gateflow-metrics-*.csv "../$BENCHMARK_DIR/" 2>/dev/null || true
) &
MONITOR_PID=$!

# Poczekaj 3 sekundy na start monitoringu
sleep 3

# Uruchom test obciążeniowy
echo "🚀 Uruchamiam test obciążeniowy..."
echo ""

(
  cd "$SCRIPT_DIR"
  ./load-test-gateflow.sh "$URL" "$REQUESTS" "$CONCURRENT" > "../$BENCHMARK_DIR/load-test.log" 2>&1
) | tee "$BENCHMARK_DIR/load-test-output.txt"

echo ""
echo "⏳ Czekam na zakończenie monitoringu..."
wait $MONITOR_PID

# Snapshot po teście
echo ""
echo "🔍 PO teście - snapshot zasobów:"

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

# Generuj raport
REPORT_FILE="$BENCHMARK_DIR/REPORT.txt"

cat > "$REPORT_FILE" << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  BENCHMARK GATEFLOW - RAPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Data:              $(date)
URL:               $URL
SSH Alias:         $SSH_ALIAS
Test Duration:     ${MONITOR_TIME}s
Total Requests:    $REQUESTS
Concurrent:        $CONCURRENT

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ZUŻYCIE ZASOBÓW
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PRZED testem:
  CPU: ${BEFORE_CPU}%
  RAM: ${BEFORE_MEM_MB} MB

PO teście:
  CPU: ${AFTER_CPU}%
  RAM: ${AFTER_MEM_MB} MB

Zmiana:
  CPU: $(python3 -c "print(round($AFTER_CPU - $BEFORE_CPU, 1))")%
  RAM: $((AFTER_MEM_MB - BEFORE_MEM_MB)) MB

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PLIKI WYJŚCIOWE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. REPORT.txt              - ten raport
2. gateflow-metrics-*.csv  - szczegółowe metryki (CSV)
3. load-test.log           - logi testu obciążeniowego
4. monitoring.log          - logi monitoringu

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ANALIZA WYDAJNOŚCI
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

# Dodaj wyniki testu do raportu
if [ -f "$BENCHMARK_DIR/load-test.log" ]; then
  echo "" >> "$REPORT_FILE"
  cat "$BENCHMARK_DIR/load-test.log" >> "$REPORT_FILE"
fi

# Dodaj podsumowanie monitoringu
if [ -f "$BENCHMARK_DIR/monitoring.log" ]; then
  echo "" >> "$REPORT_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$REPORT_FILE"
  echo "  SZCZEGÓŁY MONITORINGU" >> "$REPORT_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  tail -20 "$BENCHMARK_DIR/monitoring.log" >> "$REPORT_FILE"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Benchmark zakończony!"
echo ""
echo "📁 Wyniki zapisane w: $BENCHMARK_DIR/"
echo ""
echo "📊 Pliki:"
echo "  - REPORT.txt              (podsumowanie)"
echo "  - gateflow-metrics-*.csv  (dane do wykresu)"
echo "  - load-test.log           (szczegóły testów)"
echo ""
echo "💡 Aby zobaczyć raport:"
echo "   cat $BENCHMARK_DIR/REPORT.txt"
echo ""
echo "📈 Aby utworzyć wykres:"
echo "   Otwórz plik CSV w Excel/Google Sheets i utwórz wykres liniowy"
