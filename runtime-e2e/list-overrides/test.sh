#!/usr/bin/env bash
# Claude Code runtime E2E: list-overrides (W2 — rule #1)
#
# Drives a real Claude Code agent that should invoke the
# mcp__plugin_axonflow_axonflow__list_overrides MCP tool against the
# live stack. Empty-state success path: in community mode without any
# active overrides, the response is `{overrides: [], count: 0}`. That's
# a fully-valid runtime-path test — the agent picked the tool, dispatched
# through MCP, the platform answered, and the agent reported the count
# downstream of the result.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

PROMPT='Use the list_overrides MCP tool from the axonflow MCP server (no arguments — list all active overrides for the tenant). After receiving the tool result, output exactly "SMOKE_RESULT: " followed by a single-line JSON summary like SMOKE_RESULT: {"count":N}.'

OUTPUT_FILE=$(mktemp -t axonflow-claude-listov.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running claude -p (list_overrides) ---"
run_claude_with_tool "__list_overrides" "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_tool_invoked "$OUTPUT_FILE" "__list_overrides"; then
  echo "PASS: agent invoked an MCP tool ending in __list_overrides"
else
  echo "FAIL: agent did not invoke any *__list_overrides MCP tool"
  errors=$((errors + 1))
fi

if assert_tool_result_present "$OUTPUT_FILE" && assert_tool_result_succeeded "$OUTPUT_FILE"; then
  echo "PASS: MCP runtime returned a successful tool_result"
else
  echo "FAIL: tool_result was missing or marked is_error=true"
  errors=$((errors + 1))
fi

if assert_result_contains "$OUTPUT_FILE" "SMOKE_RESULT:"; then
  echo "PASS: agent emitted SMOKE_RESULT marker (full pipeline executed)"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

if assert_result_contains "$OUTPUT_FILE" '"count":' || assert_result_contains "$OUTPUT_FILE" "count"; then
  echo "PASS: response carries count field — list_overrides shape verified"
else
  echo "FAIL: response missing count field — server returned unexpected shape"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors runtime-path assertion(s) failed (output: $OUTPUT_FILE)"
  exit 1
fi
echo ""
echo "PASS: list-overrides — Claude Code agent dispatched list_overrides end-to-end against the live stack"
