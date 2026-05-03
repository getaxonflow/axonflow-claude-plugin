#!/usr/bin/env bash
# Claude Code runtime E2E: create-override (W2 — rule #1)
#
# Community mode does not allow override-able policies (every policy has
# allow_override=false; organization-tier policies require an Evaluation
# license). So this test exercises the dispatch path with a known
# critical-risk policy ID — the platform will return 403 ("policy is
# critical-risk") which is a valid runtime-path test outcome:
#
#   - The agent picked the tool from natural language (rule #1 ✓)
#   - Claude Code's MCP runtime dispatched the call (rule #1 ✓)
#   - The platform answered with a structured 403 (live stack reachable ✓)
#   - The agent surfaced the rejection downstream (UX ✓)
#
# When run against an evaluation-license stack with a real allow_override
# policy, runtime-e2e/governance-lifecycle/test.sh covers the full
# happy-path create + list + revoke sequence.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

runtime_e2e_skip_if_unavailable

# sys_sqli_admin_bypass exists in the seeded community policies and has
# allow_override=false. The server should return 403 — that's the
# expected runtime-path outcome here. (We are deliberately NOT testing
# the happy path because community mode blocks it; the lifecycle test
# under governance-lifecycle/ covers happy-path on evaluation+ stacks.)
PROMPT='Use the create_override MCP tool from the axonflow MCP server with policy_id="sys_sqli_admin_bypass", policy_type="static", and override_reason="runtime-e2e dispatch verification". The platform will reject this because the policy has allow_override=false. After receiving the tool result, output exactly "SMOKE_RESULT: " followed by a single-line JSON summary indicating whether the call dispatched and whether the platform returned an error, like SMOKE_RESULT: {"dispatched":true,"server_rejected":true}.'

OUTPUT_FILE=$(mktemp -t axonflow-claude-create.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running claude -p (create_override, expect 403) ---"
run_claude_with_tool "__create_override" "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_tool_invoked "$OUTPUT_FILE" "__create_override"; then
  echo "PASS: agent invoked an MCP tool ending in __create_override"
else
  echo "FAIL: agent did not invoke any *__create_override MCP tool"
  errors=$((errors + 1))
fi

if assert_tool_result_present "$OUTPUT_FILE"; then
  echo "PASS: MCP runtime returned a tool_result (live stack answered, even if 4xx)"
else
  echo "FAIL: no tool_result captured — runtime did not complete the call"
  errors=$((errors + 1))
fi

if assert_result_contains "$OUTPUT_FILE" "SMOKE_RESULT:"; then
  echo "PASS: agent emitted SMOKE_RESULT marker (full pipeline executed)"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

# Soft check that the agent recognised the rejection. Different models
# phrase 4xx differently — we surface but don't hard-fail.
if assert_result_contains "$OUTPUT_FILE" 'server_rejected' \
  || assert_result_contains "$OUTPUT_FILE" 'reject' \
  || assert_result_contains "$OUTPUT_FILE" 'allow_override' \
  || assert_result_contains "$OUTPUT_FILE" '403' ; then
  echo "INFO: agent surfaced the platform rejection (good — UX cue)"
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors runtime-path assertion(s) failed (output: $OUTPUT_FILE)"
  exit 1
fi
echo ""
echo "PASS: create-override — Claude Code agent dispatched create_override through MCP runtime end-to-end"
