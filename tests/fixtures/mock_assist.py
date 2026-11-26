"""Mock Muster Assistant server for tests (docs/assistant-and-pairing.md).

MODE env:
  normal    message -> muster_status (read) -> muster_rollback (action) -> end
  hookedit  message -> propose_hook_edit for api/deploy -> end
  badtools  message -> unknown tool + unknown service + shell metachars -> end
  402       POST /sessions -> 402 payment_required
  401       POST /sessions -> 401
  dropped   stream ends without turn_end
Every request body is appended to $LOG as {"path", "auth", "body"} lines.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = os.environ.get("MODE", "normal")
LOG = os.environ.get("LOG", "/dev/null")
turns = {"n": 0}


def ev(obj):
    return ("data: " + json.dumps(obj) + "\n\n").encode()


def text(s):
    return ev({"type": "text", "delta": s})


def end(reason):
    return ev({"type": "turn_end", "stop_reason": reason,
               "usage": {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 0}})


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def send_json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def stream(self, chunks):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for c in chunks:
            self.wfile.write(c)
            self.wfile.flush()

    def do_GET(self):
        if self.path == "/healthz":
            return self.send_json(200, {"ok": True})
        self.send_json(404, {})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body = json.loads(raw or b"{}")
        auth = self.headers.get("Authorization", "")
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": auth, "body": body}) + "\n")
        if not auth.startswith("Bearer mst_cli_"):
            return self.send_json(401, {"error": "unauthorized"})

        if self.path == "/api/assist/sessions":
            if MODE == "402":
                return self.send_json(402, {"error": "payment_required",
                                            "upgrade_url": "https://cloud.example.test/billing"})
            if MODE == "401":
                return self.send_json(401, {"error": "unauthorized"})
            return self.send_json(201, {"session_id": "sess_1", "plan": "free", "remaining_sessions": 4})

        if self.path == "/api/assist/sessions/sess_1/turns":
            turns["n"] += 1
            n = turns["n"]
            if "message" in body and n > 1 and MODE == "normal":
                return self.stream([text("Follow-up answer."), end("end_turn")])
            if MODE == "dropped":
                return self.stream([text("Partial ans")])
            if MODE == "hookedit":
                if n == 1:
                    return self.stream([
                        text("The deploy hook is missing `set -e`.\n"),
                        ev({"type": "tool_request", "tool_use_id": "tu_edit", "name": "propose_hook_edit",
                            "kind": "action", "summary": "Add set -e to the api deploy hook",
                            "input": {"service": "api", "hook": "deploy", "reason": "Fail fast on errors",
                                      "new_content": "#!/usr/bin/env bash\nset -e\necho \"api deployed\"\n"}}),
                        end("tool_use")])
                return self.stream([text("Hook updated."), end("end_turn")])
            if MODE == "allreads":
                if n == 1:
                    reqs = [
                        ("r1", "muster_history", {"service": "api", "limit": 5}),
                        ("r2", "muster_history", {}),
                        ("r3", "muster_doctor", {}),
                        ("r4", "muster_diagnose", {"service": "api"}),
                        ("r5", "muster_hooks_status", {}),
                        ("r6", "read_config", {}),
                        ("r7", "read_hook", {"service": "api", "hook": "deploy"}),
                        ("r8", "read_hook", {"service": "web", "hook": "cleanup"}),
                        ("r9", "muster_deploy", {"services": ["web"], "dry_run": True}),
                        ("r10", "muster_logs", {"service": "web", "lines": 9999}),
                    ]
                    return self.stream([ev({"type": "tool_request", "tool_use_id": i, "name": nm, "kind": "read",
                                            "summary": nm, "input": inp}) for i, nm, inp in reqs] + [end("tool_use")])
                return self.stream([text("ok"), end("end_turn")])
            if MODE == "badtools":
                if n == 1:
                    return self.stream([
                        ev({"type": "tool_request", "tool_use_id": "tu_a", "name": "rm_rf", "kind": "read",
                            "summary": "x", "input": {}}),
                        ev({"type": "tool_request", "tool_use_id": "tu_b", "name": "muster_logs", "kind": "read",
                            "summary": "x", "input": {"service": "nope", "lines": 10}}),
                        ev({"type": "tool_request", "tool_use_id": "tu_c", "name": "muster_logs", "kind": "read",
                            "summary": "x", "input": {"service": "api; rm -rf /", "lines": 10}}),
                        ev({"type": "tool_request", "tool_use_id": "tu_d", "name": "muster_rollback",
                            "kind": "read", "summary": "Sneaky rollback", "input": {"service": "api"}}),
                        end("tool_use")])
                return self.stream([text("ok"), end("end_turn")])
            # normal
            if n == 1:
                return self.stream([
                    ev({"type": "thinking_summary", "delta": "Checking status"}),
                    text("Let me check the **current** status"),
                    text(" first.\n"),
                    ev({"type": "tool_request", "tool_use_id": "tu_status", "name": "muster_status",
                        "kind": "read", "summary": "Check status", "input": {}}),
                    ev({"type": "tool_request", "tool_use_id": "tu_logs", "name": "muster_logs",
                        "kind": "read", "summary": "Read api logs", "input": {"service": "api", "lines": 50}}),
                    end("tool_use")])
            if n == 2:
                return self.stream([
                    text("The `api` deploy failed: the database password is wrong.\n"),
                    ev({"type": "tool_request", "tool_use_id": "tu_rb", "name": "muster_rollback",
                        "kind": "action", "summary": "Roll back api to the previous version",
                        "input": {"service": "api"}}),
                    end("tool_use")])
            return self.stream([
                text("## Summary\n- Rolled back **api**\n- Fix `DB_PASSWORD` in `.env`, then redeploy\n"),
                end("end_turn")])
        self.send_json(404, {})


PORT = int(sys.argv[1])
HTTPServer(("127.0.0.1", PORT), H).serve_forever()
