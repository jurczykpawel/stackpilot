# Mock Cloudflare API server using python3 http.server.
# Usage:
#   source tests/_helpers/mock-cf-server.sh
#   mock_cf_start [SCENARIO]
#   export STACKPILOT_CF_API_URL=http://127.0.0.1:$MOCK_CF_PORT
#   ... run wizard ...
#   mock_cf_stop

MOCK_CF_PID=""
MOCK_CF_PORT=""

# Scenarios: ok | invalid_token | missing_r2_scope
mock_cf_start() {
    local scenario="${1:-ok}"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local server_py="$script_dir/mock-cf-server.py"

    if [ ! -f "$server_py" ]; then
        cat > "$server_py" <<'PYEOF'
#!/usr/bin/env python3
import sys, os, json
from http.server import BaseHTTPRequestHandler, HTTPServer

SCENARIO = os.environ.get("MOCK_CF_SCENARIO", "ok")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a, **kw): pass
    def do_GET(self):
        path = self.path
        if path == "/client/v4/user/tokens/verify":
            if SCENARIO == "invalid_token":
                self._json(401, {"success": False, "errors": [{"code": 1000, "message": "Invalid API Token"}]})
            else:
                self._json(200, {"success": True, "result": {"id": "abc", "status": "active"}})
        elif path == "/client/v4/accounts":
            self._json(200, {"success": True, "result": [{"id": "acc-123", "name": "demo-account"}]})
        elif path.startswith("/client/v4/accounts/acc-123/pages/projects"):
            self._json(200, {"success": True, "result": []})
        elif path.startswith("/client/v4/accounts/acc-123/r2/buckets"):
            if SCENARIO == "missing_r2_scope":
                self._json(403, {"success": False, "errors": [{"code": 10000, "message": "Authentication error"}]})
            else:
                self._json(200, {"success": True, "result": {"buckets": []}})
        elif path.startswith("/client/v4/zones"):
            self._json(200, {"success": True, "result": []})
        else:
            self._json(404, {"error": "not found: " + path})

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    s = HTTPServer(("127.0.0.1", port), H)
    print(s.server_address[1], flush=True)
    s.serve_forever()
PYEOF
    fi

    MOCK_CF_PORT_FILE=$(mktemp)
    MOCK_CF_SCENARIO="$scenario" python3 "$server_py" 0 > "$MOCK_CF_PORT_FILE" 2>>"$MOCK_CF_PORT_FILE.err" &
    MOCK_CF_PID=$!
    # Wait for the server to print its port (max 3s)
    local i
    MOCK_CF_PORT=""
    for i in $(seq 1 30); do
        if [ -s "$MOCK_CF_PORT_FILE" ]; then
            MOCK_CF_PORT=$(head -1 "$MOCK_CF_PORT_FILE" | tr -d '[:space:]')
            break
        fi
        sleep 0.1
    done
    if [ -z "$MOCK_CF_PORT" ]; then
        echo "mock-cf-server: never printed port" >&2
        [ -f "$MOCK_CF_PORT_FILE.err" ] && cat "$MOCK_CF_PORT_FILE.err" >&2
        rm -f "$MOCK_CF_PORT_FILE" "$MOCK_CF_PORT_FILE.err"
        return 1
    fi
    for i in $(seq 1 30); do
        if curl -sS --max-time 2 -o /dev/null -w '%{http_code}' \
                "http://127.0.0.1:$MOCK_CF_PORT/client/v4/user/tokens/verify" \
                -H "Authorization: Bearer x" 2>/dev/null | grep -qE '^[0-9]+$'; then
            rm -f "$MOCK_CF_PORT_FILE" "$MOCK_CF_PORT_FILE.err"
            return 0
        fi
        sleep 0.1
    done
    echo "mock-cf-server: failed to respond on port $MOCK_CF_PORT" >&2
    [ -f "$MOCK_CF_PORT_FILE.err" ] && cat "$MOCK_CF_PORT_FILE.err" >&2
    rm -f "$MOCK_CF_PORT_FILE" "$MOCK_CF_PORT_FILE.err"
    return 1
}

mock_cf_stop() {
    if [ -n "$MOCK_CF_PID" ]; then
        kill "$MOCK_CF_PID" 2>/dev/null || true
        wait "$MOCK_CF_PID" 2>/dev/null || true
        MOCK_CF_PID=""
    fi
}
