#!/usr/bin/env bash
# Claude Code runtime E2E: the governance tools in one session, on AxonFlow
# v11.0.0, where session overrides are retired.
#
# One Claude Code session runs, in order:
#   1. list_overrides      the count before
#   2. create_override     answers the retired write (LEGACY_POLICY_WRITE_FROZEN)
#   3. list_overrides      the count after: unchanged
#   4. delete_override     answers the retired write
#   5. search_audit_events the audit read still answers
#
# Outcome assertions: every tool was invoked; both writes' tool_results are
# the retired-write tool error; both counts equal the platform's own count,
# read directly before and after the session; and the agent's final message
# reports the same. Stack posture: AXONFLOW_TRUST_IDENTITY_HEADERS=true.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

errors=0
BASELINE=$(mcp_override_count)
echo "--- list_overrides count before: ${BASELINE:-<none>} ---"

PROMPT='Run these five steps in order with the named MCP tools from the axonflow MCP server. Do not skip or reorder steps.
Step 1: call list_overrides with include_revoked=true and note its count.
Step 2: call create_override with policy_id="sys_pii_email", policy_type="static", override_reason="runtime-e2e governance-lifecycle".
Step 3: call list_overrides with include_revoked=true again and note its count.
Step 4: call delete_override with override_id="00000000-0000-4000-8000-00000000e2e1".
Step 5: call search_audit_events with limit=5.
Then reply with exactly one line: SMOKE_RESULT: followed by a JSON object with the keys "count_before" and "count_after" (numbers from steps 1 and 3), "create_frozen" and "delete_frozen" (true when that tool answer text starts with LEGACY_POLICY_WRITE_FROZEN), and "audit_answered" (true when step 5 returned a result that is not an error).'

OUTPUT_FILE=$(mktemp -t axonflow-claude-lifecycle.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Driving Claude Code through the governance tools ---"
run_claude_with_tool "__list_overrides" "$PROMPT" "$OUTPUT_FILE"

for tool in __list_overrides __create_override __delete_override __search_audit_events; do
  if assert_tool_invoked "$OUTPUT_FILE" "$tool"; then
    echo "PASS: agent invoked $tool"
  else
    echo "FAIL: agent did not invoke $tool"
    errors=$((errors + 1))
  fi
done
LIST_CALLS=$(jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name | endswith("__list_overrides")))' \
  "$OUTPUT_FILE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$LIST_CALLS" -ge 2 ]; then
  echo "PASS: agent called list_overrides $LIST_CALLS times (steps 1 and 3)"
else
  echo "FAIL: agent called list_overrides $LIST_CALLS times; the chain broke before step 3"
  errors=$((errors + 1))
fi

assert_override_frozen_text "create_override in the lifecycle" \
  "$(tool_result_is_error "$OUTPUT_FILE" "__create_override")" \
  "$(tool_result_text "$OUTPUT_FILE" "__create_override")" || errors=$((errors + 1))
assert_override_frozen_text "delete_override in the lifecycle" \
  "$(tool_result_is_error "$OUTPUT_FILE" "__delete_override")" \
  "$(tool_result_text "$OUTPUT_FILE" "__delete_override")" || errors=$((errors + 1))
if [ "$(tool_result_is_error "$OUTPUT_FILE" "__search_audit_events")" = "false" ] && \
   [ -n "$(tool_result_text "$OUTPUT_FILE" "__search_audit_events")" ]; then
  echo "PASS: search_audit_events answered a result"
else
  echo "FAIL: search_audit_events answered an error or nothing: $(tool_result_text "$OUTPUT_FILE" "__search_audit_events" | cut -c1-300)"
  errors=$((errors + 1))
fi

AFTER=$(mcp_override_count)
if [ -n "$BASELINE" ] && [ "$AFTER" = "$BASELINE" ]; then
  echo "PASS: the platform's count did not move across the session ($BASELINE -> $AFTER)"
else
  echo "FAIL: the platform's count moved or was unreadable (${BASELINE:-<none>} -> ${AFTER:-<none>})"
  errors=$((errors + 1))
fi

SMOKE=$(smoke_line "$OUTPUT_FILE")
if [ -z "$SMOKE" ]; then
  echo "FAIL: the agent's final message carried no SMOKE_RESULT"
  errors=$((errors + 1))
else
  expect=$(jq -nc --argjson b "${BASELINE:-null}" '{count_before: $b, count_after: $b, create_frozen: true, delete_frozen: true, audit_answered: true}')
  got=$(printf '%s' "$SMOKE" | jq -c '{count_before, count_after, create_frozen, delete_frozen, audit_answered}' 2>/dev/null)
  if [ "$got" = "$expect" ]; then
    echo "PASS: the agent's final message reports the platform's state ($got)"
  else
    echo "FAIL: the agent reported $got, expected $expect"
    errors=$((errors + 1))
  fi
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors lifecycle assertion(s) failed (output: $OUTPUT_FILE)"
  trap - EXIT
  exit 1
fi
echo ""
echo "PASS: governance-lifecycle — the retired writes, the unchanged reads and the audit read, end to end"
