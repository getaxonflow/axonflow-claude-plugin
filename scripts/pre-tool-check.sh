#!/usr/bin/env bash
# PreToolUse hook — evaluate tool inputs against AxonFlow governance policies.
# Matches the OpenClaw plugin's before_tool_call hook behavior.
#
# Reads tool_name and tool_input from stdin (JSON).
# Calls AxonFlow check_policy via the MCP server endpoint.
# Returns deny/allow decision based on policy evaluation.
#
# Exit 0 + JSON with permissionDecision:"deny" = structured denial
# Exit 0 + no output = allow (no opinion)
# Exit 0 + JSON with permissionDecision:"allow" = explicit allow

# Fail-open: if anything goes wrong, allow the tool call
if ! command -v jq &>/dev/null; then
  exit 0
fi
if ! command -v curl &>/dev/null; then
  exit 0
fi

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
AUTH="${AXONFLOW_AUTH:-}"

# Build auth header array safely (avoids word-splitting)
AUTH_HEADER=()
if [ -n "$AUTH" ]; then
  AUTH_HEADER=(-H "Authorization: Basic $AUTH")
fi

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

# Skip if no tool name
if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

# Derive connector type: claude_code.{ToolName}
CONNECTOR_TYPE="claude_code.${TOOL_NAME}"

# Extract the statement to evaluate based on tool type
case "$TOOL_NAME" in
  Bash)
    STATEMENT=$(echo "$TOOL_INPUT" | jq -r '.command // empty')
    ;;
  Write)
    # Check both path and content — path-based protection policies (e.g.,
    # .claude/settings, MEMORY.md) are scoped via integration activation,
    # so they only fire when the relevant integration is enabled.
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
    CONTENT=$(echo "$TOOL_INPUT" | jq -r '.content // empty' | head -c 2000)
    STATEMENT="${FILE_PATH}"$'\n'"${CONTENT}"
    ;;
  Edit)
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
    NEW_STRING=$(echo "$TOOL_INPUT" | jq -r '.new_string // empty' | head -c 2000)
    STATEMENT="${FILE_PATH}"$'\n'"${NEW_STRING}"
    ;;
  NotebookEdit)
    STATEMENT=$(echo "$TOOL_INPUT" | jq -r '.cell_content // .content // empty')
    ;;
  mcp__*)
    # MCP tools: extract query/statement field if present, else serialize input
    STATEMENT=$(echo "$TOOL_INPUT" | jq -r '.query // .statement // .command // .url // empty')
    if [ -z "$STATEMENT" ] || [ "$STATEMENT" = "null" ]; then
      STATEMENT=$(echo "$TOOL_INPUT" | jq -c '.')
    fi
    ;;
  *)
    STATEMENT=$(echo "$TOOL_INPUT" | jq -c '.')
    ;;
esac

# Skip if no statement to evaluate
if [ -z "$STATEMENT" ] || [ "$STATEMENT" = "null" ] || [ "$STATEMENT" = "{}" ]; then
  exit 0
fi

# Call AxonFlow check_policy via MCP server
RESPONSE=$(curl -s --max-time 8 -X POST "${ENDPOINT}/api/v1/mcp-server" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  "${AUTH_HEADER[@]}" \
  -d "$(jq -n \
    --arg ct "$CONNECTOR_TYPE" \
    --arg stmt "$STATEMENT" \
    '{
      jsonrpc: "2.0",
      id: "hook-pre",
      method: "tools/call",
      params: {
        name: "check_policy",
        arguments: {
          connector_type: $ct,
          statement: $stmt,
          operation: "execute"
        }
      }
    }')" 2>/dev/null || echo "")

# If AxonFlow is unreachable (empty response = network failure), fail-open
if [ -z "$RESPONSE" ]; then
  exit 0
fi

# Check for JSON-RPC error responses (auth failure, server error, etc.)
# These are NOT network failures — they indicate misconfiguration.
# Fail CLOSED on auth/config errors to prevent silent governance bypass.
JSONRPC_ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null || echo "")
if [ -n "$JSONRPC_ERROR" ]; then
  JSONRPC_CODE=$(echo "$RESPONSE" | jq -r '.error.code // 0' 2>/dev/null || echo "0")
  # Auth errors (-32001) and internal errors (-32603) = deny
  # Method not found (-32601) = likely misconfiguration = deny
  # Parse errors (-32700) = allow (could be transient)
  if [ "$JSONRPC_CODE" != "-32700" ]; then
    jq -n \
      --arg err "$JSONRPC_ERROR" \
      '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("AxonFlow governance error: " + $err + ". Fix AxonFlow configuration to restore tool access.")
        }
      }'
    exit 0
  fi
  # Parse error — likely transient, fail-open
  exit 0
fi

# Parse the MCP response to get the tool result
TOOL_RESULT=$(echo "$RESPONSE" | jq -r '.result.content[0].text // empty' 2>/dev/null || echo "")
if [ -z "$TOOL_RESULT" ]; then
  # Got a response but couldn't extract tool result — unexpected format
  # Fail-open for robustness (not an auth issue)
  exit 0
fi

# Note: jq's // operator treats false as falsy, so .allowed // true returns
# true even when .allowed is false. Use explicit if/else instead.
ALLOWED=$(echo "$TOOL_RESULT" | jq -r 'if .allowed == false then "false" else "true" end' 2>/dev/null || echo "true")
BLOCK_REASON=$(echo "$TOOL_RESULT" | jq -r '.block_reason // empty' 2>/dev/null || echo "")
POLICIES_EVALUATED=$(echo "$TOOL_RESULT" | jq -r '.policies_evaluated // 0' 2>/dev/null || echo "0")

if [ "$ALLOWED" = "false" ]; then
  # Record the blocked attempt in the audit trail (fire-and-forget).
  # This ensures blocked events appear in audit search and compliance reports.
  curl -s --max-time 5 -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
    -d "$(jq -n \
      --arg tn "$TOOL_NAME" \
      --arg stmt "$STATEMENT" \
      --arg reason "$BLOCK_REASON" \
      --arg policies "$POLICIES_EVALUATED" \
      '{
        jsonrpc: "2.0",
        id: "hook-audit-blocked",
        method: "tools/call",
        params: {
          name: "audit_tool_call",
          arguments: {
            tool_name: $tn,
            tool_type: "claude_code",
            input: {statement: $stmt},
            output: {policy_decision: "blocked", block_reason: $reason, policies_evaluated: $policies},
            success: false,
            error_message: ("Blocked by policy: " + $reason)
          }
        }
      }')" > /dev/null 2>&1 &

  # Return deny decision to Claude Code
  jq -n \
    --arg reason "$BLOCK_REASON" \
    --arg policies "$POLICIES_EVALUATED" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("AxonFlow policy violation: " + $reason + " (" + $policies + " policies evaluated)")
      }
    }'
  exit 0
fi

# Allowed — no output needed
exit 0
