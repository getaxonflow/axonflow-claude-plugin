#!/usr/bin/env bash
# Claude Code runtime E2E: list_overrides is an unchanged READ on AxonFlow
# v11.0.0, through the real MCP runtime.
#
# Session overrides are retired from v11.0.0: none can be created, so this
# suite no longer seeds one. It asserts that Claude Code invokes list_overrides,
# gets a successful tool_result carrying a count, and that the count the agent
# reports in its own final message equals the platform's (read directly over
# MCP and REST). Stack posture: AXONFLOW_TRUST_IDENTITY_HEADERS=true.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

errors=0
MCP_COUNT=$(mcp_override_count)
REST_COUNT=$(curl -s -H "Authorization: Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)" \
  -H "X-User-Email: $AXONFLOW_E2E_USER_EMAIL" "$AXONFLOW_ENDPOINT/api/v1/overrides?include_revoked=true" | jq -r '.count // empty' 2>/dev/null)
if [ -n "$MCP_COUNT" ] && [ "$MCP_COUNT" = "$REST_COUNT" ]; then
  echo "PASS: MCP list_overrides and REST GET /api/v1/overrides agree (count $MCP_COUNT)"
else
  echo "FAIL: MCP count '${MCP_COUNT:-<none>}' and REST count '${REST_COUNT:-<none>}' do not agree"
  errors=$((errors + 1))
fi

PROMPT='Use the list_overrides MCP tool from the axonflow MCP server with include_revoked=true. Then reply with exactly one line: SMOKE_RESULT: followed by a JSON object with the key "count" set to the count value in the tool answer, as a number.'

OUTPUT_FILE=$(mktemp -t axonflow-claude-listov.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running claude -p (list_overrides) ---"
run_claude_with_tool "__list_overrides" "$PROMPT" "$OUTPUT_FILE"

if assert_tool_invoked "$OUTPUT_FILE" "__list_overrides"; then
  echo "PASS: agent invoked __list_overrides"
else
  echo "FAIL: agent did not invoke __list_overrides"
  errors=$((errors + 1))
fi
if [ "$(tool_result_is_error "$OUTPUT_FILE" "__list_overrides")" = "false" ] && \
   [ -n "$(tool_result_text "$OUTPUT_FILE" "__list_overrides" | jq -r '.count // empty' 2>/dev/null)" ]; then
  echo "PASS: the tool_result is a successful read carrying a count"
else
  echo "FAIL: the tool_result was an error or carried no count: $(tool_result_text "$OUTPUT_FILE" "__list_overrides" | cut -c1-300)"
  errors=$((errors + 1))
fi

AGENT_COUNT=$(smoke_line "$OUTPUT_FILE" | jq -r '.count // empty' 2>/dev/null)
if [ -n "$AGENT_COUNT" ] && [ "$AGENT_COUNT" = "$MCP_COUNT" ]; then
  echo "PASS: the agent's final message reports the platform's count ($AGENT_COUNT)"
else
  echo "FAIL: the agent reported count '${AGENT_COUNT:-<none>}', the platform '${MCP_COUNT:-<none>}'"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors assertion(s) failed (output: $OUTPUT_FILE)"
  trap - EXIT
  exit 1
fi
echo ""
echo "PASS: list-overrides — Claude Code read the platform's override list end to end"
