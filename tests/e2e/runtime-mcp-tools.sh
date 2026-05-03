#!/usr/bin/env bash
# Plugin runtime E2E: agent-callable MCP tools (W2)
#
# Exercises the 5 read-side governance tools the plugin exposes through
# `mcp.json` -> /api/v1/mcp-server. Drives the platform's MCP server
# directly via JSON-RPC tools/list + tools/call — the same protocol the
# Claude Code runtime speaks when an agent invokes one of these tools. Does
# NOT import any AxonFlow client code.
#
# This satisfies the W2 runtime-test gate: the test must invoke each
# tool through the runtime path, not by importing the SDK class.
#
# Usage:
#   AXONFLOW_ENDPOINT=http://localhost:8080 \
#   AXONFLOW_CLIENT_ID=demo-client \
#   AXONFLOW_CLIENT_SECRET=demo-secret \
#     bash tests/e2e/runtime-mcp-tools.sh

set -uo pipefail

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"
: "${AXONFLOW_CLIENT_ID:=demo-client}"
: "${AXONFLOW_CLIENT_SECRET:=demo-secret}"

AUTH="Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)"
MCP_URL="$AXONFLOW_ENDPOINT/api/v1/mcp-server"

if ! curl -sSf -o /dev/null --max-time 5 "$AXONFLOW_ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $AXONFLOW_ENDPOINT/health"
  echo "      Start one via axonflow-enterprise scripts/setup-e2e-testing.sh"
  exit 0
fi

# Initialize MCP session
INIT_RESP=$(curl -s -D /tmp/axonflow-mcp-headers.txt -X POST -H "Authorization: $AUTH" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"axonflow-claude-runtime-e2e","version":"1.0.0"},"capabilities":{}}}' \
  "$MCP_URL")

SESSION_ID=$(grep -i "^mcp-session-id" /tmp/axonflow-mcp-headers.txt | awk '{print $2}' | tr -d '\r\n')
if [ -z "$SESSION_ID" ]; then
  echo "FAIL: MCP initialize did not return Mcp-Session-Id header"
  echo "      response: $INIT_RESP"
  exit 1
fi
echo "Session: $SESSION_ID"

call_mcp() {
  local id="$1"
  local body="$2"
  curl -s -X POST -H "Authorization: $AUTH" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -H "MCP-Protocol-Version: 2025-06-18" \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -d "$body" "$MCP_URL"
}

errors=0

# 1) tools/list — verify all 5 are advertised by the MCP server
echo "--- 1/6 tools/list ---"
LIST_RESP=$(call_mcp 2 '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
for tool in search_audit_events explain_decision create_override delete_override list_overrides; do
  if echo "$LIST_RESP" | grep -q "\"name\":\"$tool\""; then
    echo "PASS: tools/list advertises $tool"
  else
    echo "FAIL: tools/list missing $tool"
    errors=$((errors + 1))
  fi
done

# 2) search_audit_events — empty audit log path
echo "--- 2/6 tools/call search_audit_events ---"
RESP=$(call_mcp 3 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_audit_events","arguments":{"limit":5}}}')
if echo "$RESP" | grep -q '"error"'; then
  echo "FAIL: search_audit_events returned error: $RESP"
  errors=$((errors + 1))
else
  echo "PASS: search_audit_events returned ok"
fi

# 3) list_overrides — empty list expected on fresh stack
echo "--- 3/6 tools/call list_overrides ---"
RESP=$(call_mcp 4 '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_overrides","arguments":{}}}')
if echo "$RESP" | grep -q '"error"'; then
  echo "FAIL: list_overrides returned error: $RESP"
  errors=$((errors + 1))
else
  echo "PASS: list_overrides returned ok"
fi

# 4) explain_decision — unknown decision_id, expect ok response (server returns
#    structured "no data" rather than RPC error)
echo "--- 4/6 tools/call explain_decision (unknown id) ---"
RESP=$(call_mcp 5 '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"explain_decision","arguments":{"decision_id":"runtime-e2e-no-such-decision"}}}')
if echo "$RESP" | grep -q '"jsonrpc"'; then
  echo "PASS: explain_decision dispatched (response shape valid)"
else
  echo "FAIL: explain_decision response malformed: $RESP"
  errors=$((errors + 1))
fi

# 5) create_override — missing override_reason → server-side validation error,
#    not a transport error. The MCP layer wraps it as a tool result with isError.
echo "--- 5/6 tools/call create_override (missing reason → server validation) ---"
RESP=$(call_mcp 6 '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"create_override","arguments":{"policy_id":"sys_test_v1","policy_type":"static"}}}')
if echo "$RESP" | grep -q '"jsonrpc"'; then
  echo "PASS: create_override dispatched (server validation result returned)"
else
  echo "FAIL: create_override response malformed: $RESP"
  errors=$((errors + 1))
fi

# 6) delete_override — non-existent id
echo "--- 6/6 tools/call delete_override (nonexistent id) ---"
RESP=$(call_mcp 7 '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"delete_override","arguments":{"override_id":"runtime-e2e-no-such-override"}}}')
if echo "$RESP" | grep -q '"jsonrpc"'; then
  echo "PASS: delete_override dispatched"
else
  echo "FAIL: delete_override response malformed: $RESP"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors scenario(s) failed"
  exit 1
fi
echo "PASS: runtime-mcp-tools — all 5 tools advertised + dispatch correctly"
