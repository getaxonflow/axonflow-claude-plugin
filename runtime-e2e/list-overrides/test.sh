#!/usr/bin/env bash
# Claude Code runtime E2E: list-overrides OUTCOME TEST (W2 — rule #1)
#
# Outcome verification, not just dispatch. We seed a real override via
# direct API call (with a unique reason tag), drive the agent to list
# overrides via the MCP runtime, and assert the agent's reply contains
# the seeded override. The runtime-path proof is end-to-end: real state
# on the platform, agent fetched it through Claude Code's MCP, agent
# surfaced it back to the user.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

AXONFLOW_AUTH_HDR="Authorization: Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)"

# 1. Seed a real override via direct API. Use a unique reason tag we can
#    grep for in the agent's reply. sys_pii_email is overridable post-076.
REASON_TAG="list-runtime-e2e-$(date +%s)-$RANDOM"
echo "--- Seeding override with reason tag: $REASON_TAG ---"

CREATE_RESPONSE=$(curl -s -X POST \
  -H "$AXONFLOW_AUTH_HDR" \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: local-dev-org" \
  -H "X-User-Email: dev@getaxonflow.com" \
  -d "{\"policy_id\":\"sys_pii_email\",\"policy_type\":\"static\",\"override_reason\":\"$REASON_TAG\",\"ttl_seconds\":300}" \
  -w "\nHTTP_STATUS:%{http_code}" \
  "$AXONFLOW_ENDPOINT/api/v1/overrides")
CREATE_STATUS=$(printf '%s' "$CREATE_RESPONSE" | sed -n 's/^HTTP_STATUS://p')
CREATE_BODY=$(printf '%s' "$CREATE_RESPONSE" | sed '$d')

if [ "$CREATE_STATUS" != "201" ]; then
  echo "SKIP: pre-flight create_override returned HTTP $CREATE_STATUS — stack may be missing migration 076 + 070 fix-up"
  echo "      Body: $CREATE_BODY"
  exit 0
fi

SEED_ID=$(printf '%s' "$CREATE_BODY" | jq -r '.id')
echo "--- Seeded override id: $SEED_ID ---"

# Cleanup hook so we don't leak overrides across runs.
cleanup() {
  curl -s -X DELETE \
    -H "$AXONFLOW_AUTH_HDR" \
    -H "X-Tenant-ID: local-dev-org" \
    -H "X-User-Email: dev@getaxonflow.com" \
    "$AXONFLOW_ENDPOINT/api/v1/overrides/$SEED_ID" >/dev/null 2>&1 || true
  rm -f "${OUTPUT_FILE:-}"
}
trap cleanup EXIT

# 2. Drive the agent to list overrides and find our seeded one by reason tag.
PROMPT="Use the list_overrides MCP tool from the axonflow MCP server with no arguments. Look through the overrides array in the response and find the one whose override_reason field contains the substring '$REASON_TAG'. Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON like SMOKE_RESULT: {\"found\":true,\"id\":\"...\"} if you found it, or SMOKE_RESULT: {\"found\":false} if not."

OUTPUT_FILE=$(mktemp -t axonflow-claude-listov.XXXXXX)

echo "--- Driving Claude Code to list overrides and find the seeded one ---"
run_claude_with_tool "__list_overrides" "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_tool_invoked "$OUTPUT_FILE" "__list_overrides"; then
  echo "PASS: agent invoked __list_overrides"
else
  echo "FAIL: agent did not invoke __list_overrides"
  errors=$((errors + 1))
fi

if assert_tool_result_present "$OUTPUT_FILE" && assert_tool_result_succeeded "$OUTPUT_FILE"; then
  echo "PASS: MCP runtime returned a successful tool_result"
else
  echo "FAIL: tool_result was missing or is_error=true"
  errors=$((errors + 1))
fi

# Outcome assertion — agent must have actually found the seeded override.
if assert_result_contains "$OUTPUT_FILE" '"found":true'; then
  echo "PASS: agent's list_overrides returned the seeded override — outcome verified"
else
  AGENT_RESULT=$(jq -r 'select(.type=="result") | .result' "$OUTPUT_FILE" 2>/dev/null | head -3)
  echo "FAIL: agent did NOT find the seeded override via list_overrides"
  echo "      agent reply: $AGENT_RESULT"
  errors=$((errors + 1))
fi

# Stronger outcome — the agent should have echoed the SAME UUID we seeded.
if assert_result_contains "$OUTPUT_FILE" "$SEED_ID"; then
  echo "PASS: agent's reply contains the exact seeded override id ($SEED_ID)"
else
  echo "WARN: agent reply did not echo the exact UUID (model may have summarised)"
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi

echo ""
echo "PASS: list-overrides outcome — Claude Code agent found a real seeded override end-to-end"
