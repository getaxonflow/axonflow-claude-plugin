#!/usr/bin/env bash
# Claude Code runtime E2E: create_override REJECTION OUTCOME (W2 — rule #1)
#
# This test asserts the runtime dispatch path AND the rejection outcome.
# Pre-migration-076 the platform happily created an override on
# sys_sqli_admin_bypass even though the policy had severity='critical' —
# the handler's allow_override=FALSE enforcement was unreachable because
# zero seed rows had allow_override=FALSE. Migration 076 promotes
# severity='critical' system policies to risk_level='critical' which
# forces allow_override=FALSE; this test verifies the rejection now
# fires through the actual MCP runtime path.
#
# Happy-path create + list + revoke is covered by
# runtime-e2e/governance-lifecycle/test.sh against an overridable system
# policy (sys_pii_email).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

PROMPT='Use the create_override MCP tool from the axonflow MCP server with policy_id="sys_sqli_admin_bypass", policy_type="static", and override_reason="runtime-e2e rejection verification". The platform should reject this because sys_sqli_admin_bypass is severity=critical and cannot be session-overridden. After receiving the tool result, output exactly "SMOKE_RESULT: " followed by a single-line JSON like SMOKE_RESULT: {"dispatched":true,"server_rejected":true,"http_status":403} or SMOKE_RESULT: {"dispatched":true,"server_rejected":false} if the platform unexpectedly accepted the override.'

OUTPUT_FILE=$(mktemp -t axonflow-claude-create.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running claude -p (create_override on sys_sqli_admin_bypass, expect 403) ---"
run_claude_with_tool "__create_override" "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_tool_invoked "$OUTPUT_FILE" "__create_override"; then
  echo "PASS: agent invoked __create_override"
else
  echo "FAIL: agent did not invoke __create_override"
  errors=$((errors + 1))
fi

if assert_tool_result_present "$OUTPUT_FILE"; then
  echo "PASS: MCP runtime returned a tool_result (live stack answered)"
else
  echo "FAIL: no tool_result captured — runtime did not complete the call"
  errors=$((errors + 1))
fi

# Outcome assertion — the tool_result MUST carry the platform's rejection
# (not just dispatch success). Look for the orchestrator's 403 error message
# or the canonical strings the handler emits at overrides_handler.go:340/344.
TOOL_RESULT_TEXT=$(jq -c 'select(.type=="user") | .message.content[]? | select(.type=="tool_result")' \
  "$OUTPUT_FILE" 2>/dev/null | jq -r '.. | strings? // empty' | tr '\n' ' ')

if printf '%s' "$TOOL_RESULT_TEXT" | grep -q -E 'Critical-risk policies cannot be overridden|allow_override=false|cannot be session-overridden|403' ; then
  echo "PASS: tool_result carries the platform 403 rejection (migration 076 enforcement reached the agent)"
else
  echo "FAIL: tool_result did not carry the expected platform rejection"
  echo "      tool_result snippet: $(printf '%s' "$TOOL_RESULT_TEXT" | head -c 300)"
  errors=$((errors + 1))
fi

# Outcome assertion — the agent's final reply must acknowledge the rejection
# in a structured way (the SMOKE_RESULT marker JSON), not just emit a free-
# form apology. This is the "user-visible" half of the runtime claim.
if assert_result_contains "$OUTPUT_FILE" '"server_rejected":true' \
  || assert_result_contains "$OUTPUT_FILE" '"server_rejected": true'; then
  echo "PASS: agent surfaced the rejection structurally (server_rejected:true in SMOKE_RESULT)"
else
  echo "FAIL: agent did not surface server_rejected:true in SMOKE_RESULT"
  AGENT_RESULT=$(jq -r 'select(.type=="result") | .result' "$OUTPUT_FILE" 2>/dev/null | head -3)
  echo "      agent reply: $AGENT_RESULT"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed (output: $OUTPUT_FILE)"
  exit 1
fi
echo ""
echo "PASS: create-override — agent dispatched + platform rejected + agent surfaced rejection (end-to-end outcome)"
