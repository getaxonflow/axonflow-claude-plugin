#!/usr/bin/env bash
# Claude Code runtime E2E: explain-decision (W2 — rule #1)
#
# Drives a real Claude Code agent session that should invoke the
# mcp__plugin_axonflow_axonflow__explain_decision MCP tool. The
# decision_id we pass is intentionally a fabricated value — the live
# stack will return a 404 / "no explanation available" structured
# response. That's still a successful runtime-path test: the agent
# picked the tool from natural language, dispatched it through Claude
# Code's MCP runtime, the platform answered (with a structured negative),
# and the agent surfaced the negative to the user. That's the rule-#1
# evidence.
#
# When we have an evaluation-license stack with a real allow_override
# policy, runtime-e2e/governance-lifecycle/test.sh exercises the
# happy-path explain on a real decision_id surfaced from a recent
# block. This per-feature test stays focused on the runtime dispatch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

PROMPT='Use the explain_decision MCP tool from the axonflow MCP server with decision_id="runtime-e2e-fabricated-id-12345" to fetch the explanation. After receiving the tool result, output exactly "SMOKE_RESULT: " followed by a single-line JSON summary indicating whether the tool returned a not-found / no-explanation result, like SMOKE_RESULT: {"dispatched":true,"not_found":true} or SMOKE_RESULT: {"dispatched":true,"explanation_present":true}.'

OUTPUT_FILE=$(mktemp -t axonflow-claude-explain.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running claude -p (explain_decision, fabricated id) ---"
run_claude_with_tool "__explain_decision" "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_tool_invoked "$OUTPUT_FILE" "__explain_decision"; then
  echo "PASS: agent invoked an MCP tool ending in __explain_decision"
else
  echo "FAIL: agent did not invoke any *__explain_decision MCP tool"
  echo "      (this is the rule-#1 evidence — without this, we shipped wiring not a feature)"
  errors=$((errors + 1))
fi

if assert_tool_result_present "$OUTPUT_FILE"; then
  echo "PASS: MCP runtime returned a tool_result (live stack answered)"
else
  echo "FAIL: no tool_result captured — runtime did not complete the call"
  errors=$((errors + 1))
fi

if assert_result_contains "$OUTPUT_FILE" "SMOKE_RESULT:"; then
  echo "PASS: agent emitted SMOKE_RESULT marker (full pipeline executed)"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker — pipeline did not complete"
  errors=$((errors + 1))
fi

# Soft assertion: the agent recognised the not-found nature of the response.
# We don't fail the test on this — different models phrase the negative
# differently — but we surface it for grep diagnostics.
if assert_result_contains "$OUTPUT_FILE" '"not_found":true' \
  || assert_result_contains "$OUTPUT_FILE" 'not_found' \
  || assert_result_contains "$OUTPUT_FILE" 'No explanation' ; then
  echo "INFO: agent surfaced the not-found nature of the response (good — UX cue)"
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors runtime-path assertion(s) failed (output: $OUTPUT_FILE)"
  exit 1
fi
echo ""
echo "PASS: explain-decision — Claude Code agent dispatched explain_decision through MCP runtime end-to-end"
