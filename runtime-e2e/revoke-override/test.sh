#!/usr/bin/env bash
# Claude Code runtime E2E: revoke-override OUTCOME TEST (W2 — rule #1)
#
# Outcome verification, not just dispatch. We seed a real override via
# direct API, drive the agent to revoke it via the MCP runtime, then
# verify server-side that the override is in fact revoked. The runtime
# claim is "the agent's revoke command actually changes platform state",
# not just "the call dispatched".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

AXONFLOW_AUTH_HDR="Authorization: Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)"

# 1. Seed a real override via direct API.
REASON_TAG="revoke-runtime-e2e-$(date +%s)-$RANDOM"
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
  echo "SKIP: pre-flight create_override returned HTTP $CREATE_STATUS — stack may be missing migration 076"
  echo "      Body: $CREATE_BODY"
  exit 0
fi

SEED_ID=$(printf '%s' "$CREATE_BODY" | jq -r '.id')
echo "--- Seeded override id: $SEED_ID ---"

# 2. Drive the agent to revoke that exact id.
PROMPT="Use the delete_override MCP tool from the axonflow MCP server with override_id=\"$SEED_ID\". After receiving the tool result, output exactly the literal text SMOKE_RESULT: followed by a single-line JSON like SMOKE_RESULT: {\"dispatched\":true,\"revoked\":true} if the platform succeeded, or SMOKE_RESULT: {\"dispatched\":true,\"revoked\":false} on error."

OUTPUT_FILE=$(mktemp -t axonflow-claude-revoke.XXXXXX)

# Best-effort cleanup: if the agent didn't revoke, we should — leaving
# leaked active overrides across runs makes future runs flaky.
cleanup() {
  curl -s -X DELETE \
    -H "$AXONFLOW_AUTH_HDR" \
    -H "X-Tenant-ID: local-dev-org" \
    -H "X-User-Email: dev@getaxonflow.com" \
    "$AXONFLOW_ENDPOINT/api/v1/overrides/$SEED_ID" >/dev/null 2>&1 || true
  rm -f "${OUTPUT_FILE:-}"
}
trap cleanup EXIT

echo "--- Driving Claude Code to revoke $SEED_ID ---"
run_claude_with_tool "__delete_override" "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_tool_invoked "$OUTPUT_FILE" "__delete_override"; then
  echo "PASS: agent invoked __delete_override"
else
  echo "FAIL: agent did not invoke __delete_override"
  errors=$((errors + 1))
fi

if assert_tool_result_present "$OUTPUT_FILE"; then
  echo "PASS: MCP runtime returned a tool_result (live stack answered)"
else
  echo "FAIL: no tool_result captured"
  errors=$((errors + 1))
fi

# Outcome assertion — server-side state must reflect the revocation.
# This is the meaningful check: dispatch is necessary but not sufficient.
SERVER_STATE=$(curl -s -X GET \
  -H "$AXONFLOW_AUTH_HDR" \
  -H "X-Tenant-ID: local-dev-org" \
  "$AXONFLOW_ENDPOINT/api/v1/overrides?include_revoked=true" \
  | jq -r --arg id "$SEED_ID" '.overrides[]? | select(.id == $id) | .revoked_at // ""')

if [ -n "$SERVER_STATE" ] && [ "$SERVER_STATE" != "null" ]; then
  echo "PASS: server-side state shows override $SEED_ID revoked at $SERVER_STATE — outcome verified"
else
  echo "FAIL: server-side state shows override $SEED_ID NOT revoked"
  echo "      include_revoked=true result: $SERVER_STATE"
  errors=$((errors + 1))
fi

if assert_result_contains "$OUTPUT_FILE" "SMOKE_RESULT:"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed (output: $OUTPUT_FILE)"
  exit 1
fi
echo ""
echo "PASS: revoke-override outcome — agent dispatched, platform revoked the override, server state confirmed"
