#!/usr/bin/env bash
# Claude Code runtime E2E: create_override answers the RETIRED write on
# AxonFlow v11.0.0, through the real MCP runtime, and creates nothing.
#
# Session overrides are retired from v11.0.0. The platform still lists the
# create_override tool, but it answers a tool error whose text begins
# "LEGACY_POLICY_WRITE_FROZEN: " (with a per-user identity; without one it is
# refused for identity first), and REST POST /api/v1/overrides answers HTTP 409
# LEGACY_POLICY_WRITE_FROZEN. This suite asserts:
#   1. the platform's own answers, directly (MCP with X-User-Email, REST);
#   2. that Claude Code, with the plugin loaded and AXONFLOW_USER_EMAIL set,
#      invokes create_override and receives that tool error;
#   3. that the agent's own final message reports it (SMOKE_RESULT), read from
#      the stream's result event, which does not contain the prompt;
#   4. that no override was created (list_overrides count unchanged).
# Stack posture: AXONFLOW_TRUST_IDENTITY_HEADERS=true on the agent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

errors=0
EMAIL_HDR="X-User-Email: $AXONFLOW_E2E_USER_EMAIL"
BASELINE=$(mcp_override_count)
echo "--- list_overrides count before: ${BASELINE:-<none>} ---"

# 1. The platform's answers, directly.
assert_mcp_override_frozen "MCP create_override (X-User-Email)" \
  "$(mcp_tool_call create_override '{"policy_id":"sys_pii_email","policy_type":"static","override_reason":"runtime-e2e create-override (direct)"}' -H "$EMAIL_HDR")" \
  || errors=$((errors + 1))
REST=$(curl -s -X POST -H "Authorization: Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)" \
  -H "Content-Type: application/json" -H "$EMAIL_HDR" \
  -d '{"policy_id":"sys_pii_email","policy_type":"static","override_reason":"runtime-e2e create-override (REST)","ttl_seconds":300}' \
  -w "\nHTTP_STATUS:%{http_code}" "$AXONFLOW_ENDPOINT/api/v1/overrides")
assert_rest_override_frozen "REST POST /api/v1/overrides" "$(printf '%s' "$REST" | sed -n 's/^HTTP_STATUS://p')" "$(printf '%s' "$REST" | sed '$d')" \
  || errors=$((errors + 1))

# 2-3. Through Claude Code.
PROMPT='Use the create_override MCP tool from the axonflow MCP server with policy_id="sys_pii_email", policy_type="static", and override_reason="runtime-e2e create-override". Then reply with exactly one line: SMOKE_RESULT: followed by a JSON object with the key "frozen" set to true when the tool answer text starts with LEGACY_POLICY_WRITE_FROZEN and false otherwise.'

OUTPUT_FILE=$(mktemp -t axonflow-claude-create.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running claude -p (create_override, expect the retired write) ---"
run_claude_with_tool "__create_override" "$PROMPT" "$OUTPUT_FILE"

if assert_tool_invoked "$OUTPUT_FILE" "__create_override"; then
  echo "PASS: agent invoked __create_override"
else
  echo "FAIL: agent did not invoke __create_override"
  errors=$((errors + 1))
fi
assert_override_frozen_text "create_override through Claude Code" \
  "$(tool_result_is_error "$OUTPUT_FILE" "__create_override")" \
  "$(tool_result_text "$OUTPUT_FILE" "__create_override")" || errors=$((errors + 1))

SMOKE=$(smoke_line "$OUTPUT_FILE")
if [ "$(printf '%s' "$SMOKE" | jq -r '.frozen // empty' 2>/dev/null)" = "true" ]; then
  echo "PASS: the agent's final message reports the retired write ($SMOKE)"
else
  echo "FAIL: the agent's final message did not report frozen:true (SMOKE_RESULT: ${SMOKE:-<none>})"
  errors=$((errors + 1))
fi

# 4. Nothing was created.
AFTER=$(mcp_override_count)
if [ -n "$BASELINE" ] && [ "$AFTER" = "$BASELINE" ]; then
  echo "PASS: list_overrides count unchanged ($BASELINE -> $AFTER): no override was created"
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
echo "PASS: create-override — the platform and Claude Code both answer the retired write, and nothing was created"
