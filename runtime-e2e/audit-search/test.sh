#!/usr/bin/env bash
# Claude Code runtime E2E: audit-search OUTCOME TEST (W2 — rule #1)
#
# This is an outcome test, not just a dispatch test. It seeds a unique
# marker event into the platform's audit log via a real mcpCheckInput
# call, then asks Claude Code's agent to find it through audit-search,
# and asserts that the agent's reply CONTAINS the marker.
#
# The runtime-path proof is end-to-end: a real user-visible event
# happened on the platform, the agent searched for it through Claude
# Code's MCP runtime, and the agent surfaced the right entry to the
# user. That's what "audit-search works" means — not "the API returned
# 200".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

# 1. Seed a unique marker event in the audit log.
#    mcpCheckInput on benign input doesn't write an audit row (by design —
#    only block/redact/warn decisions are audited). To force a real audit
#    write we use a SQLi pattern that the platform reliably blocks
#    (sys_sqli_admin_bypass) and embed the marker as a SQL comment so the
#    audit row's `query` field contains the full statement including the
#    marker.
MARKER="w2-runtime-e2e-audit-marker-$(date +%s)-$RANDOM"
echo "--- Seeding audit marker: $MARKER ---"
SEED_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)" \
  -H "Content-Type: application/json" \
  -d "{\"connector_type\":\"sql\",\"statement\":\"SELECT * FROM users WHERE id=1 OR 1=1; -- $MARKER\",\"operation\":\"query\"}" \
  "$AXONFLOW_ENDPOINT/api/v1/mcp/check-input")
sleep 2  # give audit logger flush time

# 2. Verify the marker is in the audit log via direct curl (so we know the
#    seed actually landed before we ask the agent).
DIRECT_HITS=$(curl -s -X POST \
  -H "Authorization: Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)" \
  -H "Content-Type: application/json" \
  -d '{"limit":50}' \
  "$AXONFLOW_ENDPOINT/api/v1/audit/search" \
  | jq --arg m "$MARKER" '[.entries[] | select((.query // "") | contains($m))] | length' 2>/dev/null)
echo "Direct API saw $DIRECT_HITS audit entries containing marker"
if [ "${DIRECT_HITS:-0}" -lt 1 ]; then
  echo "FAIL: marker did not land in the audit log via direct seed — agent test would also fail"
  echo "      seed response: $SEED_RESPONSE"
  exit 1
fi

# 3. Drive the agent to find the marker via the audit-search MCP tool.
PROMPT="Use the search_audit_events MCP tool from the axonflow MCP server with limit=50 to fetch recent audit events. Then find any entry whose query field contains the substring '$MARKER' and report it. Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON like SMOKE_RESULT: {\"marker_found\":true,\"audit_id\":\"audit_...\"}. If the marker is not present in the response, output SMOKE_RESULT: {\"marker_found\":false}."

OUTPUT_FILE=$(mktemp -t axonflow-claude-audit-outcome.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Driving Claude Code to find the marker via audit-search ---"
run_claude_with_tool "__search_audit_events" "$PROMPT" "$OUTPUT_FILE"

errors=0

# Dispatch sanity (still required by rule #1)
if assert_tool_invoked "$OUTPUT_FILE" "__search_audit_events"; then
  echo "PASS: agent invoked search_audit_events via MCP runtime"
else
  echo "FAIL: agent did not invoke search_audit_events"
  errors=$((errors + 1))
fi

# Outcome assertion — agent must have actually found the marker we seeded.
if assert_result_contains "$OUTPUT_FILE" '"marker_found":true'; then
  echo "PASS: agent's audit-search returned the marker we seeded — outcome verified"
else
  AGENT_RESULT=$(jq -r 'select(.type=="result") | .result' "$OUTPUT_FILE" 2>/dev/null | head -3)
  echo "FAIL: agent did NOT find the seeded marker via audit-search"
  echo "      agent reply: $AGENT_RESULT"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi

echo ""
echo "PASS: audit-search outcome — Claude Code agent found a real marker event end-to-end"
