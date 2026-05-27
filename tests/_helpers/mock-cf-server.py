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
