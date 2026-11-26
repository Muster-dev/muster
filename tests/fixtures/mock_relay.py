"""Minimal Fleet Cloud relay for tests: device login + healthz.

MODE env: approve (default) | deny | expire
"""
import os
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
polls = {"n": 0}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == "/healthz": return self.send(200, {"status": "ok"})
        self.send(404, {})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
        if self.path == "/api/v1/device/code":
            assert body["client_name"].startswith("muster-cli on ")
            return self.send(200, {"device_code": "dc123", "user_code": "WXYZ-2345", "verification_uri": "http://localhost/device", "verification_uri_complete": "http://localhost/device?code=WXYZ-2345", "expires_in": 30, "interval": 1})
        if self.path == "/api/v1/device/token":
            polls["n"] += 1
            mode = os.environ.get("MODE", "approve")
            if polls["n"] < 2: return self.send(400, {"error": "authorization_pending"})
            if mode == "deny": return self.send(400, {"error": "access_denied"})
            if mode == "expire": return self.send(400, {"error": "expired_token"})
            return self.send(200, {"token": "mst_cli_secretvalue", "token_id": "tok_1", "org_id": "org_user_abc", "name": "muster-cli on test", "relay_url": "ws://127.0.0.1:%d" % PORT})
        self.send(404, {})
PORT = int(sys.argv[1]); HTTPServer(("127.0.0.1", PORT), H).serve_forever()
