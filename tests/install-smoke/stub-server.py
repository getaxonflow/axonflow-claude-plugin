#!/usr/bin/env python3
"""Tiny mock MCP server for the install-smoke gate.

Listens on 127.0.0.1:<port> and responds to JSON-RPC POST /api/v1/mcp-server
calls. Hard-coded responses for two scenarios the smoke gate exercises:

- "deny" — body contains a SQLi-shaped statement; respond with a check_policy
  result that includes the full Plugin Batch 1 / ADR-042 / ADR-043 set
  (decision_id, risk_level, policy_matches, override_available).
- "allow" — benign statement; respond with allowed=true and a decision_id.

No external dependencies — uses stdlib http.server.
"""

from __future__ import annotations

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

DENY_BODY = {
    "allowed": False,
    "block_reason": "Detected SQL injection pattern",
    "policies_evaluated": 12,
    "decision_id": "dec_test_deny_001",
    "risk_level": "high",
    "policy_matches": [
        {
            "policy_id": "pol-sqli-001",
            "policy_name": "SQL Injection Detection",
            "action": "block",
            "risk_level": "high",
            "allow_override": True,
            "policy_description": "Blocks classic SQLi patterns",
        }
    ],
    "override_available": True,
    "override_existing_id": None,
}

ALLOW_BODY = {
    "allowed": True,
    "policies_evaluated": 5,
    "decision_id": "dec_test_allow_001",
}


def _is_sqli(stmt: str) -> bool:
    s = stmt.lower()
    return "drop table" in s or "or 1=1" in s or "; --" in s or "union select" in s


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # silence default access log
        pass

    def do_POST(self):  # noqa: N802 - http.server contract
        if self.path != "/api/v1/mcp-server":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length).decode("utf-8") if length else "{}"
        try:
            req = json.loads(raw)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        params = (req.get("params") or {}).get("arguments") or {}
        statement = params.get("statement") or ""
        body = DENY_BODY if _is_sqli(statement) else ALLOW_BODY

        envelope = {
            "jsonrpc": "2.0",
            "id": req.get("id"),
            "result": {"content": [{"type": "text", "text": json.dumps(body)}]},
        }
        payload = json.dumps(envelope).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main() -> int:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    httpd = HTTPServer(("127.0.0.1", port), Handler)
    actual_port = httpd.server_address[1]
    print(f"stub-server listening on 127.0.0.1:{actual_port}", flush=True)
    # Print port marker for the harness to capture before serving.
    print(f"PORT={actual_port}", flush=True)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        # Block forever (until killed by harness).
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
