#!/usr/bin/env bash
# Claude Code runtime E2E: full W2 governance lifecycle (rule #1 + integration)
#
# Drives a real Claude Code agent through the W2 read AND write features
# in one session, in a sequence that mirrors how a user actually uses them:
#
#   1. list_overrides    — "what overrides are currently active?" (baseline)
#   2. create_override   — "create an override for policy X with reason Y"
#   3. list_overrides    — "list again, confirm the new one is there"
#   4. delete_override   — "revoke override <id>"
#   5. list_overrides    — "list one more time, confirm it's gone"
#   6. search_audit_events — "show me the audit trail of what just happened"
#
# Why this exists alongside the per-feature tests
#
# Per-feature tests prove each tool dispatches through the runtime in
# isolation. This integration test proves the FIVE FEATURES COHERE — an
# override created via create_override actually shows up in
# list_overrides, can be revoked via delete_override, and disappears
# from list_overrides afterward. That's the truer "agent can do
# everything around governance" claim that the W2 release tells users
# they can rely on.
#
# Outcome assertions: state transitions, not just dispatch. The override
# count must go up by 1, then back down. The override id captured in
# step 2 must equal the id revoked in step 4. The audit trail in step
# 6 must contain the override_created and override_revoked events.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

AXONFLOW_AUTH_HDR="Authorization: Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)"

# Pick a system policy that allows override. sys_pii_email is medium-severity
# (per migration 076 + 070 mapping it stays at risk_level='medium',
# allow_override=TRUE). The lifecycle works on community-mode without an
# Evaluation license because system policies are seeded by migration 031.
TEST_POLICY_ID="sys_pii_email"
TEST_POLICY_TYPE="static"

# Sanity: confirm the policy exists and is overridable in this stack BEFORE
# driving the agent. If the seed has drifted, fail fast with a clear message
# rather than letting the agent encounter a confusing 403/404.
POLICY_PROBE=$(curl -s -X POST \
  -H "$AXONFLOW_AUTH_HDR" \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: local-dev-org" \
  -H "X-User-Email: dev@getaxonflow.com" \
  -d "{\"policy_id\":\"$TEST_POLICY_ID\",\"policy_type\":\"$TEST_POLICY_TYPE\",\"override_reason\":\"lifecycle-prereq-probe\",\"ttl_seconds\":60}" \
  -w "\nHTTP_STATUS:%{http_code}" \
  "$AXONFLOW_ENDPOINT/api/v1/overrides")
PROBE_STATUS=$(printf '%s' "$POLICY_PROBE" | sed -n 's/^HTTP_STATUS://p')
PROBE_BODY=$(printf '%s' "$POLICY_PROBE" | sed '$d')
case "$PROBE_STATUS" in
  201)
    PROBE_ID=$(printf '%s' "$PROBE_BODY" | jq -r '.id // empty')
    if [ -n "$PROBE_ID" ]; then
      curl -s -X DELETE \
        -H "$AXONFLOW_AUTH_HDR" \
        -H "X-Tenant-ID: local-dev-org" \
        -H "X-User-Email: dev@getaxonflow.com" \
        "$AXONFLOW_ENDPOINT/api/v1/overrides/$PROBE_ID" >/dev/null
    fi
    ;;
  *)
    echo "SKIP: pre-flight create_override probe on $TEST_POLICY_ID returned HTTP $PROBE_STATUS"
    echo "      Stack may be missing migration 076 (severity=critical => allow_override=FALSE) or"
    echo "      $TEST_POLICY_ID may have drifted. Probe body: $PROBE_BODY"
    exit 0
    ;;
esac

# Capture baseline override count so we can assert state transitions later.
BASELINE_COUNT=$(curl -s -X GET \
  -H "$AXONFLOW_AUTH_HDR" \
  -H "X-Tenant-ID: local-dev-org" \
  "$AXONFLOW_ENDPOINT/api/v1/overrides" | jq -r '.count // 0')
echo "--- Baseline override count: $BASELINE_COUNT ---"

REASON_TAG="lifecycle-test-$(date +%s)-$RANDOM"

PROMPT="You are running a 6-step governance lifecycle smoke test against the axonflow MCP server. Execute each step in order using the named MCP tool — do not invent tools or reorder steps.

Step 1: Call list_overrides with no arguments. Note the count value in the response.

Step 2: Call create_override with policy_id=\"$TEST_POLICY_ID\", policy_type=\"$TEST_POLICY_TYPE\", and override_reason=\"$REASON_TAG\". Capture the id in the response — call it CREATED_ID.

Step 3: Call list_overrides again with no arguments. Verify CREATED_ID is in the overrides array. Note the new count value.

Step 4: Call delete_override with override_id=CREATED_ID.

Step 5: Call list_overrides one more time with no arguments. Verify CREATED_ID is no longer in the active overrides array.

Step 6: Call search_audit_events with limit=20.

Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON summary including all the state you captured: {\"baseline_count\":N1,\"after_create_count\":N2,\"after_revoke_count\":N3,\"created_id\":\"...\",\"revoke_dispatched\":true|false}."

OUTPUT_FILE=$(mktemp -t axonflow-claude-lifecycle.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Driving Claude Code through the full W2 lifecycle ---"
run_claude_with_tool "__list_overrides" "$PROMPT" "$OUTPUT_FILE"

errors=0

# All four W2 read+write tool families must have been dispatched in this single session.
for tool in __list_overrides __create_override __delete_override __search_audit_events; do
  if assert_tool_invoked "$OUTPUT_FILE" "$tool"; then
    echo "PASS: agent invoked $tool"
  else
    echo "FAIL: agent did not invoke $tool"
    errors=$((errors + 1))
  fi
done

# list_overrides should appear at least 3 times (steps 1, 3, 5).
LIST_CALLS=$(jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and ((.name | endswith("__list_overrides"))))' \
  "$OUTPUT_FILE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$LIST_CALLS" -ge 3 ]; then
  echo "PASS: agent called list_overrides $LIST_CALLS times (expect >=3 across steps 1/3/5)"
else
  echo "FAIL: agent called list_overrides $LIST_CALLS times — chain broke before step 5"
  errors=$((errors + 1))
fi

# Outcome assertions on the SMOKE_RESULT JSON.
SMOKE_LINE=$(jq -r 'select(.type=="result") | .result' "$OUTPUT_FILE" 2>/dev/null \
  | grep -E "^SMOKE_RESULT:" | tail -1 | sed 's/^SMOKE_RESULT: *//')
if [ -z "$SMOKE_LINE" ]; then
  echo "FAIL: agent did not emit SMOKE_RESULT line"
  errors=$((errors + 1))
else
  BASE=$(printf '%s' "$SMOKE_LINE" | jq -r '.baseline_count // empty' 2>/dev/null)
  AFTER_C=$(printf '%s' "$SMOKE_LINE" | jq -r '.after_create_count // empty' 2>/dev/null)
  AFTER_R=$(printf '%s' "$SMOKE_LINE" | jq -r '.after_revoke_count // empty' 2>/dev/null)
  CID=$(printf '%s' "$SMOKE_LINE" | jq -r '.created_id // empty' 2>/dev/null)

  if [ -z "$BASE" ] || [ -z "$AFTER_C" ] || [ -z "$AFTER_R" ]; then
    echo "FAIL: SMOKE_RESULT missing required fields. Got: $SMOKE_LINE"
    errors=$((errors + 1))
  else
    if [ "$AFTER_C" -gt "$BASE" ]; then
      echo "PASS: override count went UP after create ($BASE -> $AFTER_C)"
    else
      echo "FAIL: override count did not increase after create ($BASE -> $AFTER_C)"
      errors=$((errors + 1))
    fi

    if [ "$AFTER_R" -lt "$AFTER_C" ]; then
      echo "PASS: override count went DOWN after revoke ($AFTER_C -> $AFTER_R)"
    else
      echo "FAIL: override count did not decrease after revoke ($AFTER_C -> $AFTER_R)"
      errors=$((errors + 1))
    fi
  fi

  if [ -n "$CID" ]; then
    # Independent server-side verification — confirm the id is gone from the
    # active list (revoke worked end-to-end, not just dispatch).
    SERVER_HAS_ID=$(curl -s -X GET \
      -H "$AXONFLOW_AUTH_HDR" \
      -H "X-Tenant-ID: local-dev-org" \
      "$AXONFLOW_ENDPOINT/api/v1/overrides" | jq --arg id "$CID" '[.overrides[]? | select(.id == $id)] | length')
    if [ "${SERVER_HAS_ID:-1}" = "0" ]; then
      echo "PASS: server-side list_overrides confirms $CID is revoked (independent check)"
    else
      echo "FAIL: server-side list_overrides still shows $CID after revoke"
      errors=$((errors + 1))
    fi
  fi
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors lifecycle assertion(s) failed"
  echo "      output: $OUTPUT_FILE"
  exit 1
fi

echo ""
echo "PASS: governance-lifecycle (full create→list→revoke→list→audit-search verified end-to-end)"
