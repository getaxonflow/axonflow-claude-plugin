#!/usr/bin/env bash
# Shared helpers for Claude Code runtime-e2e tests.
#
# Each per-feature test sources this file and calls run_claude with a
# tool name + prompt. The helpers handle env/skip checks, plugin path,
# stream-json parsing, and the rule-#1 invariants (tool actually
# invoked + tool_result returned + agent emitted SMOKE_RESULT marker).

set -uo pipefail

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"
: "${AXONFLOW_CLIENT_ID:=demo-client}"
: "${AXONFLOW_CLIENT_SECRET:=demo-secret}"

# Skip path is the same for every test — extract for clarity.
runtime_e2e_skip_if_unavailable() {
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
}

# run_claude_with_tool <tool-suffix> <prompt> <output-file>
#
# tool-suffix matches the suffix of the namespaced MCP tool name
# (Claude Code prefixes plugin tools as
# `mcp__plugin_<plugin-id>_<server>__<tool>`). e.g.
# `__explain_decision`.
run_claude_with_tool() {
  local tool_suffix="$1"
  local prompt="$2"
  local output_file="$3"

  export AXONFLOW_ENDPOINT
  export AXONFLOW_AUTH
  AXONFLOW_AUTH="$(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)"

  local plugin_dir
  plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  local tmpdir
  tmpdir="$(mktemp -d -t axonflow-claude-e2e.XXXXXX)"

  ( cd "$tmpdir" && claude \
    --plugin-dir "$plugin_dir" \
    --print \
    --output-format stream-json \
    --include-partial-messages \
    --verbose \
    --allowedTools "mcp__axonflow__*" \
    --dangerously-skip-permissions \
    "$prompt" 2>&1 ) > "$output_file" || true
  rm -rf "$tmpdir"
}

# Returns 0 if the agent invoked any MCP tool whose name ends in
# <tool-suffix>; 1 otherwise.
assert_tool_invoked() {
  local output_file="$1"
  local tool_suffix="$2"
  local invoked
  invoked=$(jq -c --arg s "$tool_suffix" \
    'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name | endswith($s)))' \
    "$output_file" 2>/dev/null | head -1)
  [ -n "$invoked" ]
}

# Returns 0 if a tool_result block was captured (regardless of is_error).
assert_tool_result_present() {
  local output_file="$1"
  local r
  r=$(jq -c 'select(.type=="user") | .message.content[]? | select(.type=="tool_result")' \
    "$output_file" 2>/dev/null | head -1)
  [ -n "$r" ]
}

# Returns 0 if the tool_result's is_error is false (or absent).
assert_tool_result_succeeded() {
  local output_file="$1"
  local is_error
  is_error=$(jq -c 'select(.type=="user") | .message.content[]? | select(.type=="tool_result")' \
    "$output_file" 2>/dev/null | head -1 | jq -r '.is_error // false')
  [ "$is_error" != "true" ]
}

# Returns 0 if the agent's final result text contains the substring.
assert_result_contains() {
  local output_file="$1"
  local needle="$2"
  jq -r 'select(.type=="result") | .result' "$output_file" 2>/dev/null | grep -q "$needle"
}
