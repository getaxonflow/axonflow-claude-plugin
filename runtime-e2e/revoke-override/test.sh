#!/usr/bin/env bash
# Claude Code runtime E2E: delete_override answers the RETIRED write on
# AxonFlow v11.0.0, through the real MCP runtime.
#
# Session overrides are retired from v11.0.0: no override can be created, and
# the delete_override tool answers a tool error whose text begins
# "LEGACY_POLICY_WRITE_FROZEN: " (REST DELETE /api/v1/overrides/<id> answers
# HTTP 409). This suite asserts the platform's answers directly, then that
# Claude Code invokes delete_override and receives that tool error, that the
# agent's own final message reports it, and that the list_overrides count did
# not move. Stack posture: AXONFLOW_TRUST_IDENTITY_HEADERS=true on the agent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

errors=0
EMAIL_HDR="X-User-Email: $AXONFLOW_E2E_USER_EMAIL"
# Any id: nothing can be created, so there is no real one to revoke.
PROBE_ID="00000000-0000-4000-8000-00000000e2e0"
BASELINE=$(mcp_override_count)
echo "--- list_overrides count before: ${BASELINE:-<none>} ---"

assert_mcp_override_frozen "MCP delete_override (X-User-Email)" \
  "$(mcp_tool_call delete_override "{\"override_id\":\"$PROBE_ID\"}" -H "$EMAIL_HDR")" \
  || errors=$((errors + 1))
REST=$(curl -s -X DELETE -H "Authorization: Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)" \
  -H "$EMAIL_HDR" -w "\nHTTP_STATUS:%{http_code}" "$AXONFLOW_ENDPOINT/api/v1/overrides/$PROBE_ID")
assert_rest_override_frozen "REST DELETE /api/v1/overrides/<id>" "$(printf '%s' "$REST" | sed -n 's/^HTTP_STATUS://p')" "$(printf '%s' "$REST" | sed '$d')" \
  || errors=$((errors + 1))

PROMPT="Use the delete_override MCP tool from the axonflow MCP server with override_id=\"$PROBE_ID\". Then reply with exactly one line: SMOKE_RESULT: followed by a JSON object with the key \"frozen\" set to true when the tool answer text starts with LEGACY_POLICY_WRITE_FROZEN and false otherwise."

OUTPUT_FILE=$(mktemp -t axonflow-claude-revoke.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running claude -p (delete_override, expect the retired write) ---"
run_claude_with_tool "__delete_override" "$PROMPT" "$OUTPUT_FILE"

if assert_tool_invoked "$OUTPUT_FILE" "__delete_override"; then
  echo "PASS: agent invoked __delete_override"
else
  echo "FAIL: agent did not invoke __delete_override"
  errors=$((errors + 1))
fi
assert_override_frozen_text "delete_override through Claude Code" \
  "$(tool_result_is_error "$OUTPUT_FILE" "__delete_override")" \
  "$(tool_result_text "$OUTPUT_FILE" "__delete_override")" || errors=$((errors + 1))

SMOKE=$(smoke_line "$OUTPUT_FILE")
if [ "$(printf '%s' "$SMOKE" | jq -r '.frozen // empty' 2>/dev/null)" = "true" ]; then
  echo "PASS: the agent's final message reports the retired write ($SMOKE)"
else
  echo "FAIL: the agent's final message did not report frozen:true (SMOKE_RESULT: ${SMOKE:-<none>})"
  errors=$((errors + 1))
fi

AFTER=$(mcp_override_count)
if [ -n "$BASELINE" ] && [ "$AFTER" = "$BASELINE" ]; then
  echo "PASS: list_overrides count unchanged ($BASELINE -> $AFTER)"
else
  echo "FAIL: list_overrides count moved or was unreadable (${BASELINE:-<none>} -> ${AFTER:-<none>})"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors assertion(s) failed (output: $OUTPUT_FILE)"
  trap - EXIT
  exit 1
fi
echo ""
echo "PASS: revoke-override — the platform and Claude Code both answer the retired write"
