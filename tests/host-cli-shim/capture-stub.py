#!/usr/bin/env python3
"""Capturing JSON-RPC stub for the host-CLI shim test.

Listens on 127.0.0.1:<port> and answers the agent endpoints the plugin
calls during a tool-call lifecycle:

  POST /api/v1/mcp-server   — JSON-RPC tools/call: dispatches on `params.name`
                              (check_policy / audit_tool_call / check_output)
                              and returns a Plugin-Batch-1-shaped envelope
                              wrapping the canned per-tool body.
  GET  /health              — liveness probe

Every request is appended (method, path, headers, body) to a JSONL file
the shim runner inspects to assert which paths/tools were exercised AND
which headers (notably X-License-Token + Authorization) reached the wire.

Stdlib only. The harness reads the listening port from the
"PORT=<n>" line written to stdout at startup.

Deny path: the runner sends a statement containing `deny-me` to trigger
DENY_POLICY_BODY; benign statements get ALLOW_POLICY_BODY.
"""

from __future__ import annotations

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

CAPTURE_FILE = os.environ.get("CAPTURE_FILE", "/tmp/host-cli-shim-capture.jsonl")

ALLOW_POLICY_BODY = {
    "allowed": True,
    "policies_evaluated": 3,
    "decision_id": "dec_shim_allow_001",
}

DENY_POLICY_BODY = {
    "allowed": False,
    "block_reason": "stub-deny",
    "policies_evaluated": 12,
    "decision_id": "dec_shim_deny_001",
    "risk_level": "high",
    "policy_matches": [
        {
            "policy_id": "pol-shim-001",
            "policy_name": "Shim deny rule",
            "action": "block",
            "risk_level": "high",
            "allow_override": False,
        }
    ],
    "override_available": False,
}

AUDIT_BODY = {"recorded": True, "audit_id": "aud_shim_001"}
CHECK_OUTPUT_BODY = {"pii_detected": False, "redacted_output": ""}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # silence default access log
        pass

    def _read_body(self) -> str:
        length = int(self.headers.get("content-length", "0"))
        return self.rfile.read(length).decode("utf-8") if length else ""

    def _capture(self, body: str, tool_name: str = "") -> None:
        record = {
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body,
            "tool_name": tool_name,
        }
        with open(CAPTURE_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")

    def _json(self, status: int, payload: dict) -> None:
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _mcp_envelope(self, req_id, body: dict) -> dict:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"content": [{"type": "text", "text": json.dumps(body)}]},
        }

    def do_GET(self):  # noqa: N802
        self._capture("")
        if self.path == "/health":
            self._json(200, {"status": "healthy", "tier": "community"})
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):  # noqa: N802
        body = self._read_body()
        try:
            req = json.loads(body) if body else {}
        except json.JSONDecodeError:
            req = {}
        params = req.get("params") or {}
        tool_name = params.get("name") or ""
        self._capture(body, tool_name=tool_name)

        if self.path != "/api/v1/mcp-server":
            self.send_response(404)
            self.end_headers()
            return

        args = params.get("arguments") or {}
        statement = (args.get("statement") or args.get("query") or "").lower()

        if tool_name == "check_policy":
            payload = DENY_POLICY_BODY if "deny-me" in statement else ALLOW_POLICY_BODY
        elif tool_name == "audit_tool_call":
            payload = AUDIT_BODY
        elif tool_name == "check_output":
            payload = CHECK_OUTPUT_BODY
        else:
            payload = {"error": f"stub: unknown tool {tool_name!r}"}

        self._json(200, self._mcp_envelope(req.get("id"), payload))


def main() -> int:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    if os.path.exists(CAPTURE_FILE):
        os.remove(CAPTURE_FILE)
    httpd = HTTPServer(("127.0.0.1", port), Handler)
    actual_port = httpd.server_address[1]
    print(f"capture-stub listening on 127.0.0.1:{actual_port}", flush=True)
    print(f"PORT={actual_port}", flush=True)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
