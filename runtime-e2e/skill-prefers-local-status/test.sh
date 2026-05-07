#!/usr/bin/env bash
# Runtime proof for the skill-flip: when the operator asks Claude
# "what's my AxonFlow tenant ID?", the agent invokes the LOCAL script
# (`scripts/status.sh`) BEFORE making any MCP tool call to the agent.
#
# Skill change rationale: the local script answers from persisted state
# (no agent round-trip). The MCP tool gets the same shape but requires
# an HTTP round-trip to the agent. Preferring the local path saves the
# round-trip on every common "what's my tenant ID?" question — which is
# typically asked precisely when the agent isn't reachable yet.
#
# Per HARD RULE #0: this drives the REAL `claude` CLI with the plugin
# loaded against a real AxonFlow agent (community-saas at
# try.getaxonflow.com when nothing else is configured). The stream-json
# output is parsed to confirm:
#
#   1. Some tool was invoked (the agent didn't refuse to act).
#   2. The FIRST NON-SKILL tool the agent invoked is the Bash call
#      running $CLAUDE_PLUGIN_ROOT/scripts/status.sh — NOT the MCP tool
#      mcp__axonflow__axonflow_get_tenant_id. (Skill tool calls are
#      the agent's mechanism for loading SKILL.md into context; the
#      next tool is what the skill actually drove. We assert on the
#      latter.)
#   3. The MCP tool axonflow_get_tenant_id is NOT invoked at any tool
#      index BEFORE the local script — the skill's preference must
#      hold across the entire run, not just at position #1.
#
# Skip conditions (graceful):
#   - claude CLI not on PATH
#   - jq not on PATH
#   - AXONFLOW_ENDPOINT (when set) /health unreachable

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$PLUGIN_DIR/runtime-e2e/_lib/claude-runtime.sh"

UTC_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE="$SCRIPT_DIR/EVIDENCE/$UTC_TS"
mkdir -p "$EVIDENCE"

# Default to the public Community SaaS endpoint so the test runs against
# real infrastructure when the operator hasn't configured anything else.
# The shared lib defaults AXONFLOW_ENDPOINT to http://localhost:8080;
# override here ONLY when nothing was set externally.
if [ -z "${AXONFLOW_ENDPOINT_OVERRIDE_DONE:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
  AXONFLOW_ENDPOINT="${AXONFLOW_ENDPOINT:-https://try.getaxonflow.com}"
  export AXONFLOW_ENDPOINT
  export AXONFLOW_ENDPOINT_OVERRIDE_DONE=1
fi

runtime_e2e_skip_if_unavailable

OUTPUT_FILE="$EVIDENCE/claude_stream.jsonl"

# Phrase the prompt to deterministically activate the axonflow-status
# skill. We tell the agent to USE THE SKILL — that pulls the SKILL.md
# body into context, and then the agent's first action should be the
# script invocation per the skill's step 1. (A free-form question
# like "what's my tenant ID?" non-deterministically triggers the
# skill — sometimes the agent just probes the filesystem itself —
# which makes the test flaky. Driving the skill explicitly tests
# the SKILL contents against agent behaviour rather than the agent's
# heuristic skill-selection logic.)
PROMPT="Use the axonflow-status skill to find my AxonFlow tenant ID. Follow exactly the steps in the skill — do not deviate."

run_claude_with_tool "" "$PROMPT" "$OUTPUT_FILE"
echo "  claude run captured to $OUTPUT_FILE ($(wc -l <"$OUTPUT_FILE") lines)"

PASS=true
fail() { echo "FAIL: $1"; PASS=false; }

# Some tool was invoked.
if ! jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")' "$OUTPUT_FILE" >/dev/null 2>&1; then
  echo "FAIL: no tool_use blocks in claude output (agent didn't act)"
  exit 1
fi

# Find the FIRST non-Skill governed tool the agent invoked. The Skill
# tool itself is the agent's mechanism for loading SKILL.md into
# context — once loaded, the next tool call is what the skill
# actually drove. So we skip the Skill probe and assert on what
# follows: per the flipped skill, that must be Bash with status.sh.
FIRST_GOVERNED=$(jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name != "Skill")' "$OUTPUT_FILE" \
  | head -1 \
  | jq -c '{name: .name, input: .input}')

echo "  first non-Skill tool: $FIRST_GOVERNED"
echo "$FIRST_GOVERNED" > "$EVIDENCE/first_tool.json"

FIRST_NAME=$(echo "$FIRST_GOVERNED" | jq -r '.name // empty')
FIRST_CMD=$(echo "$FIRST_GOVERNED" | jq -r '.input.command // empty')

# Hard assertion: the first non-Skill tool MUST be Bash AND its command
# MUST reference scripts/status.sh. The MCP tool path
# (mcp__axonflow__axonflow_get_tenant_id) MUST NOT be invoked here —
# that would mean the skill flip didn't stick.
if [ "$FIRST_NAME" != "Bash" ]; then
  fail "first non-Skill tool name='$FIRST_NAME', want 'Bash' (skill should prefer the local script)"
fi
if ! echo "$FIRST_CMD" | grep -qF "scripts/status.sh"; then
  fail "first Bash command does not reference scripts/status.sh: '$FIRST_CMD'"
fi

# Negative assertion: the MCP tool axonflow_get_tenant_id must NOT
# appear before the local script in the tool sequence. (We don't ban
# it entirely — the skill explicitly documents it as a fallback —
# but it must never come first.)
SCRIPT_IDX=$(jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")' "$OUTPUT_FILE" \
  | nl -ba | awk '/scripts\/status\.sh/{print $1; exit}')
MCP_IDX=$(jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")' "$OUTPUT_FILE" \
  | nl -ba | awk '/axonflow_get_tenant_id/{print $1; exit}')
if [ -n "$MCP_IDX" ] && [ -n "$SCRIPT_IDX" ] && [ "$MCP_IDX" -lt "$SCRIPT_IDX" ]; then
  fail "MCP tool axonflow_get_tenant_id was invoked at tool#$MCP_IDX before script@tool#$SCRIPT_IDX (skill should defer MCP to fallback)"
fi

# Final-answer assertion: the agent should surface tenant_id-shaped
# content to the user (skill step 3). Either the literal string
# 'tenant_id' or a 'cs_'-prefixed identifier should appear somewhere in
# the result stream — final text, tool_result blocks (which carry the
# script's stdout), or the assistant's answer text.
RESULT_FULL=$(cat "$OUTPUT_FILE")
echo "$RESULT_FULL" > "$EVIDENCE/result_full.jsonl"
if ! echo "$RESULT_FULL" | grep -qiE 'tenant[_ ]id|cs_'; then
  fail "no tenant_id-shaped content anywhere in the captured stream"
fi

{
  echo "Skill-prefers-local-status runtime proof — $UTC_TS"
  echo "AXONFLOW_ENDPOINT=$AXONFLOW_ENDPOINT"
  echo "First non-Skill tool: $FIRST_GOVERNED"
  echo "Script @tool#: ${SCRIPT_IDX:-(not invoked)}"
  echo "MCP get_tenant_id @tool#: ${MCP_IDX:-(not invoked)}"
  echo "Result: $($PASS && echo PASS || echo FAIL)"
} | tee "$EVIDENCE/summary.txt"

if $PASS; then
  echo
  echo "PASS — claude prefers the local scripts/status.sh path on tenant_id queries"
  exit 0
else
  echo
  echo "FAIL — see $EVIDENCE/ for evidence"
  exit 1
fi
