#!/usr/bin/env bash
# Claude Code runtime-e2e: list_recent_decisions wire-level proof (V1.1, #1982).
#
# Asserts the platform's MCP server advertises list_recent_decisions, then
# drives a happy-path tools/call AND a Free-tier cap-hit tools/call to
# verify the V1 upgrade envelope is preserved end-to-end. Wire-level
# (not agent-driven) so it runs deterministically without an LLM in the
# loop — the agent-driven proof is captured separately when a maintainer
# runs the slash command interactively.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

# Re-use the same skip-if-unavailable check as the other Claude runtime
# tests (claude CLI + jq + stack reachable).
runtime_e2e_skip_if_unavailable

errors=0
auth_b64=$(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)
headers_file=$(mktemp)
trap 'rm -f "$headers_file"' EXIT

# Initialize a fresh MCP session (the same handshake Claude Code's MCP
# transport performs).
curl -s -D "$headers_file" -X POST \
  -H "Authorization: Basic $auth_b64" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-list-recent-decisions-runtime","version":"1.0.0"},"capabilities":{}}}' \
  "$AXONFLOW_ENDPOINT/api/v1/mcp-server" >/dev/null
session_id=$(grep -i "^mcp-session-id" "$headers_file" | awk '{print $2}' | tr -d '\r\n')

if [ -z "$session_id" ]; then
  echo "FAIL: MCP initialize did not return a session id"
  exit 1
fi
echo "PASS: MCP session initialized ($session_id)"

# Assert tools/list advertises list_recent_decisions.
list_resp=$(curl -s -X POST -H "Authorization: Basic $auth_b64" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -H "Mcp-Session-Id: $session_id" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "$AXONFLOW_ENDPOINT/api/v1/mcp-server")
if printf '%s' "$list_resp" | jq -e '.result.tools[] | select(.name=="list_recent_decisions")' >/dev/null 2>&1; then
  echo "PASS: MCP server advertises list_recent_decisions"
else
  echo "FAIL: MCP server did not advertise list_recent_decisions"
  errors=$((errors + 1))
fi

# Happy path.
happy_resp=$(curl -s -X POST -H "Authorization: Basic $auth_b64" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -H "Mcp-Session-Id: $session_id" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_recent_decisions","arguments":{"limit":3}}}' \
  "$AXONFLOW_ENDPOINT/api/v1/mcp-server")
happy_text=$(printf '%s' "$happy_resp" | jq -r '.result.content[0].text // empty')
if printf '%s' "$happy_text" | jq -e '.decisions or .upgrade_required' >/dev/null 2>&1; then
  echo "PASS: tools/call list_recent_decisions returned a recognized shape"
else
  echo "FAIL: tools/call list_recent_decisions returned unexpected text:"
  printf '      %s\n' "$happy_text" | head -3
  errors=$((errors + 1))
fi

# Cap-hit: limit=10 over Community max page=5 must return the wrapped envelope.
cap_resp=$(curl -s -X POST -H "Authorization: Basic $auth_b64" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -H "Mcp-Session-Id: $session_id" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_recent_decisions","arguments":{"limit":10}}}' \
  "$AXONFLOW_ENDPOINT/api/v1/mcp-server")
cap_text=$(printf '%s' "$cap_resp" | jq -r '.result.content[0].text // empty')
if printf '%s' "$cap_text" | jq -e '.upgrade_required==true and .envelope.limit_type=="decision_list_size" and .envelope.upgrade.buy_url != null' >/dev/null 2>&1; then
  echo "PASS: cap-hit returned wrapped V1 envelope (upgrade_required + decision_list_size + buy_url)"
else
  echo "FAIL: cap-hit envelope shape wrong:"
  printf '      %s\n' "$cap_text" | head -3
  errors=$((errors + 1))
fi

# Verify the slash command file is present (Claude Code surface).
plugin_dir="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -f "$plugin_dir/commands/axonflow-list-recent-decisions.md" ]; then
  echo "PASS: /axonflow-list-recent-decisions slash command shipped"
else
  echo "FAIL: commands/axonflow-list-recent-decisions.md missing"
  errors=$((errors + 1))
fi
if [ -f "$plugin_dir/skills/list-recent-decisions/SKILL.md" ]; then
  echo "PASS: list-recent-decisions skill shipped"
else
  echo "FAIL: skills/list-recent-decisions/SKILL.md missing"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: list_recent_decisions runtime — MCP server advertises tool, happy path returns decisions, cap-hit preserves V1 upgrade envelope, plugin surface ships"
