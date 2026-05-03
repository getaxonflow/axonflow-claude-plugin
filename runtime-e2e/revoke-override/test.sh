#!/usr/bin/env bash
# Claude Code runtime E2E: revoke-override (W2 — rule #1)
#
# Drives a real Claude Code agent that should invoke
# mcp__plugin_axonflow_axonflow__delete_override (the platform-side name
# for the revoke-override tool). We pass an override_id that does not
# exist; the platform returns 404. That's a valid runtime-path test:
#
#   - Agent picked the tool from natural language
#   - MCP runtime dispatched the call
#   - Platform answered with a structured 404
#   - Agent surfaced the not-found result downstream
#
# Happy-path (revoke a real override) lives in
# runtime-e2e/governance-lifecycle/test.sh which requires an
# evaluation-license stack to seed an override-able policy.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

PROMPT='Use the delete_override MCP tool from the axonflow MCP server with override_id="runtime-e2e-fabricated-override-id-12345". The platform will return a 404 because that override does not exist. After receiving the tool result, output exactly "SMOKE_RESULT: " followed by a single-line JSON summary indicating dispatch status, like SMOKE_RESULT: {"dispatched":true,"not_found":true}.'

OUTPUT_FILE=$(mktemp -t axonflow-claude-revoke.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running claude -p (delete_override, fabricated id, expect 404) ---"
run_claude_with_tool "__delete_override" "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_tool_invoked "$OUTPUT_FILE" "__delete_override"; then
  echo "PASS: agent invoked an MCP tool ending in __delete_override"
else
  echo "FAIL: agent did not invoke any *__delete_override MCP tool"
  errors=$((errors + 1))
fi

if assert_tool_result_present "$OUTPUT_FILE"; then
  echo "PASS: MCP runtime returned a tool_result (live stack answered)"
else
  echo "FAIL: no tool_result captured"
  errors=$((errors + 1))
fi

if assert_result_contains "$OUTPUT_FILE" "SMOKE_RESULT:"; then
  echo "PASS: agent emitted SMOKE_RESULT marker (full pipeline executed)"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

if assert_result_contains "$OUTPUT_FILE" 'not_found' \
  || assert_result_contains "$OUTPUT_FILE" '404' \
  || assert_result_contains "$OUTPUT_FILE" 'does not exist' ; then
  echo "INFO: agent surfaced the not-found result (good — UX cue)"
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors runtime-path assertion(s) failed (output: $OUTPUT_FILE)"
  exit 1
fi
echo ""
echo "PASS: revoke-override — Claude Code agent dispatched delete_override through MCP runtime end-to-end"
