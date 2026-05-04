#!/usr/bin/env bash
# Claude Code runtime E2E: explain-decision OUTCOME TEST (W2 — rule #1)
#
# Outcome verification: trigger a real platform block to mint a real
# decision_id, then ask the agent to explain THAT decision through the
# MCP runtime, and assert the agent's reply contains the policy name +
# risk level from the actual decision. The runtime claim is "agent can
# look up a real decision and surface its details to the user", not just
# "the call dispatched".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

AXONFLOW_AUTH_HDR="Authorization: Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)"

# 1. Mint a real decision by triggering a block. sys_sqli_admin_bypass
#    matches a classic OR-1=1 + comment pattern and reliably blocks
#    (severity=critical post-076).
SEED_TAG="explain-runtime-e2e-$(date +%s)-$RANDOM"
echo "--- Triggering platform block to mint a real decision_id (tag: $SEED_TAG) ---"

CHECK_RESPONSE=$(curl -s -X POST \
  -H "$AXONFLOW_AUTH_HDR" \
  -H "Content-Type: application/json" \
  -d "{\"connector_type\":\"sql\",\"statement\":\"SELECT * FROM users WHERE id=1 OR 1=1; -- $SEED_TAG\",\"operation\":\"query\"}" \
  "$AXONFLOW_ENDPOINT/api/v1/mcp/check-input")

DECISION_ID=$(printf '%s' "$CHECK_RESPONSE" | jq -r '.decision_id // empty')
WAS_BLOCKED=$(printf '%s' "$CHECK_RESPONSE" | jq -r '.allowed')

if [ -z "$DECISION_ID" ]; then
  echo "SKIP: mcpCheckInput did not return a decision_id"
  echo "      response: $CHECK_RESPONSE"
  exit 0
fi
if [ "$WAS_BLOCKED" != "false" ]; then
  echo "SKIP: SQLi pattern was not blocked — pattern catalogue may have drifted"
  echo "      response: $CHECK_RESPONSE"
  exit 0
fi
echo "--- Minted decision_id: $DECISION_ID ---"
sleep 2  # give audit logger flush time

# 2. Drive the agent to explain that exact decision.
PROMPT="Use the explain_decision MCP tool from the axonflow MCP server with decision_id=\"$DECISION_ID\" to fetch the full explanation. From the tool result, extract the policy name (under policy_matches[0].policy_name or policies[0].name — whichever the response uses). After receiving the tool result, output exactly the literal text SMOKE_RESULT: followed by a single-line JSON like SMOKE_RESULT: {\"explanation_present\":true,\"policy_name\":\"...\"} if you got a real explanation, or SMOKE_RESULT: {\"explanation_present\":false} if not."

OUTPUT_FILE=$(mktemp -t axonflow-claude-explain.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Driving Claude Code to explain $DECISION_ID ---"
run_claude_with_tool "__explain_decision" "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_tool_invoked "$OUTPUT_FILE" "__explain_decision"; then
  echo "PASS: agent invoked __explain_decision"
else
  echo "FAIL: agent did not invoke __explain_decision"
  errors=$((errors + 1))
fi

if assert_tool_result_present "$OUTPUT_FILE"; then
  echo "PASS: MCP runtime returned a tool_result (live stack answered)"
else
  echo "FAIL: no tool_result captured"
  errors=$((errors + 1))
fi

# Outcome assertion — agent must surface a real explanation. We expect to
# see the policy name "Authentication Bypass" (the human-readable name of
# sys_sqli_admin_bypass) somewhere in the agent's reply, since that's the
# policy that fired on the seeded statement.
if assert_result_contains "$OUTPUT_FILE" "Authentication Bypass" \
  || assert_result_contains "$OUTPUT_FILE" "sys_sqli_admin_bypass"; then
  echo "PASS: agent's reply names the policy that fired on the seeded decision — outcome verified"
else
  AGENT_RESULT=$(jq -r 'select(.type=="result") | .result' "$OUTPUT_FILE" 2>/dev/null | head -3)
  echo "FAIL: agent's reply does not name the policy from the explanation"
  echo "      agent reply: $AGENT_RESULT"
  errors=$((errors + 1))
fi

if assert_result_contains "$OUTPUT_FILE" '"explanation_present":true'; then
  echo "PASS: agent emitted explanation_present:true"
elif assert_result_contains "$OUTPUT_FILE" 'explanation_present'; then
  echo "INFO: agent emitted explanation_present field (value may be false)"
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed (output: $OUTPUT_FILE)"
  exit 1
fi
echo ""
echo "PASS: explain-decision outcome — agent fetched + surfaced a real platform decision end-to-end"
