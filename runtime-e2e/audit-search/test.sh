#!/usr/bin/env bash
# Plugin runtime E2E: real Claude Code agent invokes MCP tools (W2 — rule #1).
#
# This is the runtime-path test the W2 work has been missing. It loads the
# actual plugin into a real Claude Code session via `claude --plugin-dir`,
# sends a non-interactive prompt that should trigger one of the new MCP
# tools, captures the streaming JSON output, and asserts the agent invoked
# the tool through Claude Code's tool dispatcher — NOT through a direct
# JSON-RPC call we composed ourselves.
#
# Why this matters
#
# Rule #1 (no user-facing feature merges without one runtime-path test):
# the user surface here is "agent picks an MCP tool from natural-language
# context and invokes it." Direct JSON-RPC tools/call against /api/v1/mcp-server
# tests the wire under the surface — it does NOT test that Claude actually
# discovers, picks, and dispatches the tool. This script tests that.
#
# Usage:
#   AXONFLOW_ENDPOINT=http://localhost:8080 \
#   AXONFLOW_CLIENT_ID=demo-client \
#   AXONFLOW_CLIENT_SECRET=demo-secret \
#     bash tests/e2e/runtime-real-agent.sh
#
# Requirements:
#   - `claude` CLI on PATH and authenticated (OAuth or ANTHROPIC_API_KEY)
#   - jq on PATH
#   - Live AxonFlow stack reachable at AXONFLOW_ENDPOINT
#
# Exits 0 with SKIP when claude isn't authenticated or the stack isn't up,
# so the script is safe to run on CI hosts that don't have either.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"
: "${AXONFLOW_CLIENT_ID:=demo-client}"
: "${AXONFLOW_CLIENT_SECRET:=demo-secret}"

if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude CLI not on PATH"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi
if ! curl -sSf -o /dev/null --max-time 5 "$AXONFLOW_ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $AXONFLOW_ENDPOINT/health"
  echo "      Start one via axonflow-enterprise scripts/setup-e2e-testing.sh"
  exit 0
fi

# The plugin's .mcp.json points at $AXONFLOW_ENDPOINT and reads $AXONFLOW_AUTH
# (Basic-auth-encoded creds). Claude Code expands those env vars at MCP-config
# load time, so the real runtime sees the right URL + creds.
export AXONFLOW_ENDPOINT
export AXONFLOW_AUTH
AXONFLOW_AUTH="$(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)"

# Use a temp working dir so the agent doesn't see our repo's CLAUDE.md / hooks.
TMPDIR_RUN="$(mktemp -d -t axonflow-claude-e2e.XXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

echo "--- Plugin: $PLUGIN_DIR"
echo "--- Endpoint: $AXONFLOW_ENDPOINT"
echo "--- Working dir: $TMPDIR_RUN"

# Drive a real Claude Code agent session non-interactively. The prompt is
# explicit because we want to assert the *plumbing* works — not measure how
# well Claude infers the right tool from a vague hint. (Inferring is its own
# question; the runtime-path test cares whether the call gets dispatched
# when Claude decides to make it.)
PROMPT='Use the search_audit_events MCP tool from the axonflow MCP server to fetch the most recent 5 audit events. Set limit=5 and leave start_time/end_time at their defaults. Then summarize what you got back as a JSON object on a single line, prefixed with the literal text "SMOKE_RESULT: " — for example: SMOKE_RESULT: {"total":0,"first_id":null}'

echo "--- Running claude -p ... ---"
RAW_OUTPUT=$(cd "$TMPDIR_RUN" && claude \
  --plugin-dir "$PLUGIN_DIR" \
  --print \
  --output-format stream-json \
  --include-partial-messages \
  --verbose \
  --allowedTools "mcp__axonflow__search_audit_events" \
  --dangerously-skip-permissions \
  "$PROMPT" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

echo "--- claude exit: $EXIT_CODE ---"

# Save full output for debugging.
OUTPUT_FILE="$TMPDIR_RUN/claude-output.jsonl"
printf '%s\n' "$RAW_OUTPUT" >"$OUTPUT_FILE"
echo "--- Captured ${RAW_OUTPUT}c bytes of stream output (saved to $OUTPUT_FILE)"

errors=0

# Assertion 1: Claude actually invoked an MCP tool from the axonflow server.
# In stream-json output, tool invocations appear as assistant content blocks
# with type="tool_use". Claude Code namespaces plugin-provided MCP tools as
# `mcp__plugin_<plugin-id>_<server-name>__<tool>` — for this plugin that's
# `mcp__plugin_axonflow_axonflow__search_audit_events`. We match suffix
# `__search_audit_events` to be tolerant of that naming convention without
# coupling to its exact prefix shape.
TOOL_USE_LINE=$(printf '%s' "$RAW_OUTPUT" \
  | jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name | endswith("__search_audit_events")))' 2>/dev/null \
  | head -1)

if [ -z "$TOOL_USE_LINE" ]; then
  echo "FAIL: agent did not invoke any *__search_audit_events MCP tool"
  echo "      (this is the rule-#1 evidence — without this, we shipped wiring not a feature)"
  errors=$((errors + 1))
else
  TOOL_NAME=$(printf '%s' "$TOOL_USE_LINE" | jq -r '.name')
  echo "PASS: agent invoked $TOOL_NAME"
fi

# Assertion 2: the MCP server returned a successful tool result, not an error.
# Tool results appear as type="user" messages with content[].type="tool_result".
TOOL_RESULT_LINE=$(printf '%s' "$RAW_OUTPUT" \
  | jq -c 'select(.type=="user") | .message.content[]? | select(.type=="tool_result")' 2>/dev/null \
  | head -1)

if [ -z "$TOOL_RESULT_LINE" ]; then
  echo "FAIL: no tool_result captured for the MCP call (server unreachable or runtime error)"
  errors=$((errors + 1))
else
  IS_ERROR=$(printf '%s' "$TOOL_RESULT_LINE" | jq -r '.is_error // false' 2>/dev/null)
  if [ "$IS_ERROR" = "true" ]; then
    echo "FAIL: tool_result.is_error=true (the MCP tool call returned an error)"
    printf '%s\n' "$TOOL_RESULT_LINE" | jq -r '.content[]?.text // empty' 2>/dev/null | head -3 | sed 's/^/      /'
    errors=$((errors + 1))
  else
    echo "PASS: tool_result returned successfully"
  fi
fi

# Assertion 3: the agent's final answer carries the SMOKE_RESULT marker —
# proves the agent actually consumed the tool result and produced a response
# downstream of it (not just dispatched and stopped).
if printf '%s' "$RAW_OUTPUT" | jq -r 'select(.type=="result") | .result' 2>/dev/null | grep -q "SMOKE_RESULT:"; then
  echo "PASS: agent emitted SMOKE_RESULT marker (full pipeline executed)"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker — pipeline did not complete"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors runtime-path assertion(s) failed"
  echo "      Full stream output: $OUTPUT_FILE"
  exit 1
fi
echo ""
echo "PASS: runtime-real-agent — Claude Code agent dispatched mcp__axonflow__search_audit_events end-to-end against the live stack"
