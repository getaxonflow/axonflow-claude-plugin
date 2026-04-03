#!/usr/bin/env bash
# PreToolUse hook — evaluate tool inputs against AxonFlow governance policies.
# Matches the OpenClaw plugin's before_tool_call hook behavior.
#
# Reads tool_name and tool_input from stdin (JSON).
# Calls AxonFlow check_policy via the MCP server endpoint.
# Returns deny/allow decision based on policy evaluation.
set -euo pipefail

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
AUTH="${AXONFLOW_AUTH:-}"

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
  Write|Edit)
    STATEMENT=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
    ;;
  NotebookEdit)
    STATEMENT=$(echo "$TOOL_INPUT" | jq -r '.cell_content // .content // empty')
    ;;
  mcp__*)
    # MCP tools: serialize entire input as the statement
    STATEMENT=$(echo "$TOOL_INPUT" | jq -c '.')
    ;;
  *)
    # Unknown tools: serialize entire input
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
  ${AUTH:+-H "Authorization: Basic $AUTH"} \
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

# If AxonFlow is unreachable, fail-open (allow)
if [ -z "$RESPONSE" ]; then
  exit 0
fi

# Parse the MCP response to get the tool result
TOOL_RESULT=$(echo "$RESPONSE" | jq -r '.result.content[0].text // empty' 2>/dev/null || echo "")
if [ -z "$TOOL_RESULT" ]; then
  exit 0
fi

ALLOWED=$(echo "$TOOL_RESULT" | jq -r '.allowed // true' 2>/dev/null || echo "true")
BLOCK_REASON=$(echo "$TOOL_RESULT" | jq -r '.block_reason // empty' 2>/dev/null || echo "")
POLICIES_EVALUATED=$(echo "$TOOL_RESULT" | jq -r '.policies_evaluated // 0' 2>/dev/null || echo "0")

if [ "$ALLOWED" = "false" ]; then
  # Blocked by policy — deny the tool call
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

# Allowed — no output needed, exit 0
exit 0
