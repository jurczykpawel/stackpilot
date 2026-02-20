# Monitoring GateFlow

Guide to tools for monitoring performance and resource usage of the GateFlow application on your VPS.

## Quick Start

### Basic PM2 Monitoring

```bash
# Application status
ssh ALIAS "pm2 status"

# Real-time monitoring
ssh ALIAS "pm2 monit"

# Logs (last 50 lines)
ssh ALIAS "pm2 logs gateflow-admin --lines 50"
```

### Full Benchmark (test + monitoring)

```bash
# Run with one command
./local/benchmark-gateflow.sh https://shop.your-domain.com ALIAS

# With heavier load
./local/benchmark-gateflow.sh https://shop.your-domain.com ALIAS 500 30
```

## Available Tools

### 1. monitor-gateflow.sh

Continuous monitoring of CPU and RAM usage by the GateFlow application.

**Usage:**
```bash
./local/monitor-gateflow.sh <ssh_alias> [time_in_seconds] [app_name]
```

**Examples:**
```bash
# Monitor for 60 seconds (default)
./local/monitor-gateflow.sh ALIAS

# Monitor for 5 minutes
./local/monitor-gateflow.sh ALIAS 300

# Specific instance (multi-instance setup)
./local/monitor-gateflow.sh ALIAS 300 gateflow-shop
```

**Output:**
- Real-time metrics (progress bar)
- CSV file with data: `gateflow-metrics-YYYYMMDD-HHMMSS.csv`
- Summary: CPU/RAM (max, average)
- Recommendation: whether the app will fit on a 2GB VPS

**CSV Columns:**
- `timestamp` - Date and time of measurement
- `cpu_percent` - CPU usage (%)
- `memory_mb` - RAM (MB)
- `memory_percent` - Percentage of available memory
- `uptime_min` - Uptime (minutes)
- `restarts` - Number of restarts
- `status` - Process status (online/stopped)

**Visualization:**
1. Open the CSV file in Excel/Google Sheets
2. Select columns: `timestamp`, `cpu_percent`, `memory_mb`
3. Insert -> Chart -> Line chart
4. You have a resource usage chart over time!

---

### 2. load-test-gateflow.sh

Load test for the application - simulates user traffic.

**Usage:**
```bash
./local/load-test-gateflow.sh <url> [number_of_requests] [concurrency]
```

**Examples:**
```bash
# Basic test (50 requests, 5 concurrent)
./local/load-test-gateflow.sh https://shop.your-domain.com

# Medium test (100 requests, 10 concurrent)
./local/load-test-gateflow.sh https://shop.your-domain.com 100 10

# Large test (500 requests, 20 concurrent)
./local/load-test-gateflow.sh https://shop.your-domain.com 500 20

# Stress test (1000 requests, 50 concurrent)
./local/load-test-gateflow.sh https://shop.your-domain.com 1000 50
```

**Test scenario (realistic endpoint mix):**
- 20% - Homepage
- 30% - Product list
- 30% - Product details
- 20% - User profile

**Output:**
- Real-time progress bar
- Success rate (% of successful requests)
- Response times: min/average/max
- Performance rating:
  - < 500ms - Excellent
  - 500-1000ms - Good
  - 1-2s - Average
  - > 2s - Poor

**Interpreting results:**

| Average time | Rating | Notes |
|-------------|--------|-------|
| < 300ms | Excellent | App is very fast |
| 300-500ms | Great | Superb performance |
| 500-800ms | Good | Acceptable for most users |
| 800-1500ms | Average | Users may notice delays |
| > 1500ms | Poor | Needs optimization |

---

### 3. benchmark-gateflow.sh

**Best tool!** Combines load testing + resource monitoring.

**Usage:**
```bash
./local/benchmark-gateflow.sh <url> <ssh_alias> [requests] [concurrency]
```

**Examples:**
```bash
# Quick benchmark (100 requests)
./local/benchmark-gateflow.sh https://shop.your-domain.com ALIAS

# Medium benchmark (200 requests, 20 concurrent)
./local/benchmark-gateflow.sh https://shop.your-domain.com ALIAS 200 20

# Large benchmark (500 requests, 30 concurrent)
./local/benchmark-gateflow.sh https://shop.your-domain.com ALIAS 500 30
```

**What it does:**
1. Takes a resource snapshot BEFORE the test
2. Starts monitoring in the background
3. Runs the load test
4. Takes a resource snapshot AFTER the test
5. Generates a complete report

**Output (folder `benchmark-YYYYMMDD-HHMMSS/`):**
- `REPORT.txt` - Complete text report
- `gateflow-metrics-*.csv` - Data for charting
- `load-test.log` - Detailed test logs
- `monitoring.log` - Detailed monitoring logs

**Report contains:**
- Resource comparison before/after test
- CPU and RAM usage changes
- Load test results
- Metrics summary
- Recommendations

---

## Practical Examples

### Case 1: "Checking if it fits on a 2GB VPS"

```bash
# 1. Install the app on a test server
./local/deploy.sh gateflow --ssh=ALIAS --domain=auto

# 2. Run benchmark
./local/benchmark-gateflow.sh https://test.your-domain.com ALIAS 200 20

# 3. Check the report
cat benchmark-*/REPORT.txt

# 4. Look for in the report:
#    - Max RAM < 500 MB? -> Fits
#    - Max RAM 500-700 MB? -> Acceptable
#    - Max RAM > 700 MB? -> Need a larger VPS (2GB+)
```

### Case 2: "How does it behave under load?"

```bash
# 1. Start long monitoring (10 minutes)
./local/monitor-gateflow.sh ALIAS 600 &

# 2. In another terminal - load test
./local/load-test-gateflow.sh https://shop.your-domain.com 1000 50

# 3. Wait for monitoring to finish

# 4. Open CSV in Excel and view the chart
#    Look for:
#    - Does RAM grow linearly? (memory leak?)
#    - Does CPU drop after test? (returns to idle?)
#    - Were there restarts? ('restarts' column)
```

### Case 3: "Comparison before and after optimization"

```bash
# BEFORE optimization
./local/benchmark-gateflow.sh https://shop.your-domain.com ALIAS 300 30
mv benchmark-* benchmark-before/

# ... (make changes) ...

# AFTER optimization
./local/benchmark-gateflow.sh https://shop.your-domain.com ALIAS 300 30
mv benchmark-* benchmark-after/

# Compare
diff benchmark-before/REPORT.txt benchmark-after/REPORT.txt
```

### Case 4: "Continuous production monitoring"

Use PM2 Plus (free dashboard):

```bash
# 1. Register: https://app.pm2.io
# 2. Create a bucket (free)
# 3. On the server:
ssh ALIAS "pm2 link <SECRET_KEY> <PUBLIC_KEY>"

# Now you have:
# - Dashboard in the browser
# - Real-time CPU/RAM charts
# - Metrics history (24h on free plan)
# - Email alerts on errors
```

---

## Troubleshooting

### Problem: High RAM (> 500 MB on low traffic)

**Check:**
```bash
# Are there memory leaks?
./local/monitor-gateflow.sh ALIAS 600  # 10 minutes
# Open CSV and check if RAM keeps growing
```

**Possible causes:**
- Next.js cache grows without limit
- Supabase client is not reused
- WebSocket connections are not closed

**Solution:**
- Add `NODE_OPTIONS='--max-old-space-size=512'` in PM2 config
- Restart: `ssh ALIAS "pm2 restart gateflow-admin"`

### Problem: High CPU in idle (> 5% without traffic)

**Check:**
```bash
# Snapshot without traffic
ssh ALIAS "pm2 list"
ssh ALIAS "pm2 monit"  # Watch for 2 minutes

# Logs - look for repeating operations
ssh ALIAS "pm2 logs gateflow-admin --lines 200"
```

**Possible causes:**
- Polling to Supabase
- Suboptimal queries in Next.js Middleware
- Hot reload (DEV mode - should not be in production!)

**Solution:**
- Check `NODE_ENV`: `ssh ALIAS "grep NODE_ENV ~/gateflow/admin-panel/.env.local"`
- Must be `NODE_ENV=production`!

### Problem: Slow response times (> 1s average)

**Check:**
```bash
# Test from different locations
./local/load-test-gateflow.sh https://shop.your-domain.com 50 5

# Check if all endpoints are slow or only some
curl -w "@curl-format.txt" -o /dev/null -s https://shop.your-domain.com
curl -w "@curl-format.txt" -o /dev/null -s https://shop.your-domain.com/products
```

**Possible causes:**
- No Cloudflare cache (check cache rules)
- Suboptimal Supabase queries
- Missing database indexes
- Server overloaded (check `ssh ALIAS "htop"`)

**Solution:**
```bash
# Enable Cloudflare cache
./local/setup-cloudflare-optimize.sh shop.your-domain.com

# Check Supabase query performance
# Dashboard -> Performance -> Query Insights
```

### Problem: App crashes under load

**Check:**
```bash
# Gradual load test
./local/load-test-gateflow.sh https://shop.your-domain.com 10 2   # OK?
./local/load-test-gateflow.sh https://shop.your-domain.com 50 5   # OK?
./local/load-test-gateflow.sh https://shop.your-domain.com 100 10 # Crash?

# Logs during crash
ssh ALIAS "pm2 logs gateflow-admin --lines 500 --err"

# Check restart count
ssh ALIAS "pm2 show gateflow-admin"
```

**Possible causes:**
- Not enough RAM (OOM Killer)
- Unhandled promise rejections
- Timeout on DB connections

**Solution:**
- Increase RAM: upgrade to a 2GB VPS
- Add error handling in API routes
- Increase Supabase connection pool

---

## Reference Metrics

### 1GB RAM VPS

| Metric | Idle | Low traffic | Medium traffic | High traffic |
|--------|------|-------------|----------------|--------------|
| RAM | 250-300 MB | 300-400 MB | 400-500 MB | 500-600 MB |
| CPU | 1-3% | 5-15% | 15-30% | 30-60% |
| Response time | 100-200ms | 200-400ms | 400-800ms | 800-1500ms |
| Concurrent users | - | ~5 | ~10-15 | ~20-30 |

### 2GB RAM VPS

| Metric | Idle | Low traffic | Medium traffic | High traffic |
|--------|------|-------------|----------------|--------------|
| RAM | 250-300 MB | 300-450 MB | 450-700 MB | 700-1000 MB |
| CPU | 1-3% | 5-15% | 15-30% | 30-60% |
| Response time | 100-200ms | 200-350ms | 350-600ms | 600-1000ms |
| Concurrent users | - | ~10 | ~20-30 | ~50-80 |

**Note:** These are values for standard GateFlow with Supabase. Your results may vary depending on:
- Number of products
- Query complexity
- Image sizes
- External integrations (Stripe, Turnstile)

---

## Best Practices

### 1. Regular monitoring

```bash
# Check daily
ssh ALIAS "pm2 status"

# Weekly - full report
./local/benchmark-gateflow.sh https://shop.your-domain.com ALIAS 100 10

# Keep history
mkdir -p benchmarks/
mv benchmark-* benchmarks/
```

### 2. Alerts

Configure PM2 Plus (free) for alerts:
- Application down > 2 minutes
- CPU > 80% for 5 minutes
- RAM > 90% for 3 minutes
- More than 3 restarts within an hour

### 3. Progressive optimization

1. **Baseline** - first benchmark (save as reference point)
2. **Cache** - enable Cloudflare cache (`setup-cloudflare-optimize.sh`)
3. **Benchmark** - did it help?
4. **Images** - optimize images (WebP, lazy loading)
5. **Benchmark** - did it help?
6. **Queries** - optimize Supabase queries
7. **Benchmark** - did it help?

**Make only one change at a time!** Then you know what helped.

### 4. Tests before deployment

```bash
# Before each update
./local/benchmark-gateflow.sh https://test.your-domain.com ALIAS 200 20

# If results are OK - deploy to production
./local/deploy.sh gateflow --ssh=prod-server --update

# After deploy - check if performance degraded
./local/benchmark-gateflow.sh https://shop.example.com prod-server 200 20
```

---

## Additional Tools

### PM2 Keymetrics (free)

```bash
ssh ALIAS "pm2 link <SECRET> <PUBLIC>"
```

**Dashboard:** https://app.pm2.io

**Provides:**
- Metric charts (24h history)
- Email/Slack alerts
- Error tracking
- Log management
- Remote restart/reload

### Grafana + Prometheus (advanced)

If you need professional monitoring:
1. Install `prom-client` in GateFlow
2. Expose `/metrics` endpoint
3. Configure Prometheus on the server
4. Connect Grafana

**Documentation:** https://github.com/siimon/prom-client

---

## FAQ

**Q: Can I monitor multiple instances simultaneously?**

A: Yes! Benchmark each separately:
```bash
./local/benchmark-gateflow.sh https://shop1.example.com ALIAS
./local/benchmark-gateflow.sh https://shop2.example.com ALIAS
```

**Q: How often should I run benchmarks?**

A:
- **After each update** - make sure nothing got worse
- **Once a week** - track the trend
- **Before scaling** - do I need an upgrade?

**Q: What to do if tests show too high RAM usage?**

A:
1. Check for memory leaks (monitor for 10 min)
2. Optimize cache (add limits)
3. If nothing helps - upgrade to a larger VPS

**Q: How to simulate even heavier load?**

A: Use `ab` (Apache Bench) or `wrk`:
```bash
# Install
brew install wrk  # macOS
apt install wrk   # Linux

# Test
wrk -t12 -c400 -d30s https://shop.your-domain.com
```

**Q: Do these scripts work with other applications (not just GateFlow)?**

A: Yes! All PM2 scripts work with any PM2-managed application. Just provide the process name:
```bash
./local/monitor-gateflow.sh ALIAS 300 n8n-server
./local/monitor-gateflow.sh ALIAS 300 uptime-kuma
```

---

**Pro Tip:** Run a benchmark before purchasing a VPS. Install GateFlow on a free service (Railway, Render free tier) and run `benchmark-gateflow.sh`. If RAM < 500 MB - a 1GB VPS is sufficient. If RAM > 500 MB - you need a 2GB VPS.
