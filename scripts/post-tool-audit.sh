#!/usr/bin/env bash
# PostToolUse hook — audit logging and output scanning.
# Matches the OpenClaw plugin's after_tool_call + message_sending hooks.
#
# 1. Records tool execution in AxonFlow audit trail (after_tool_call equivalent)
# 2. Scans tool output for PII/secrets (check_output equivalent)
#
# Both are fire-and-forget — audit/scan failures never block tool execution.
set -euo pipefail

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
AUTH="${AXONFLOW_AUTH:-}"

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')
TOOL_RESPONSE=$(echo "$INPUT" | jq -c '.tool_response // {}')

# Skip if no tool name
if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

CONNECTOR_TYPE="claude_code.${TOOL_NAME}"

# Determine success from tool response
SUCCESS=$(echo "$TOOL_RESPONSE" | jq -r 'if .exitCode then (.exitCode == 0) elif .success then .success else true end' 2>/dev/null || echo "true")
ERROR_MSG=$(echo "$TOOL_RESPONSE" | jq -r '.stderr // empty' 2>/dev/null || echo "")

# Truncate large outputs for audit (max 500 chars)
TRUNCATED_OUTPUT=$(echo "$TOOL_RESPONSE" | jq -c '.' | head -c 500)

# 1. Record audit entry (fire-and-forget)
curl -s --max-time 5 -X POST "${ENDPOINT}/api/v1/mcp-server" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  ${AUTH:+-H "Authorization: Basic $AUTH"} \
  -d "$(jq -n \
    --arg tn "$TOOL_NAME" \
    --argjson ti "$TOOL_INPUT" \
    --arg out "$TRUNCATED_OUTPUT" \
    --argjson success "$SUCCESS" \
    --arg err "$ERROR_MSG" \
    '{
      jsonrpc: "2.0",
      id: "hook-audit",
      method: "tools/call",
      params: {
        name: "audit_tool_call",
        arguments: {
          tool_name: $tn,
          tool_type: "claude_code",
          input: $ti,
          output: {summary: $out},
          success: $success,
          error_message: $err
        }
      }
    }')" > /dev/null 2>&1 &

# 2. Scan tool output for PII/secrets (fire-and-forget)
# Extract text content from tool response for scanning
OUTPUT_TEXT=""
case "$TOOL_NAME" in
  Bash)
    OUTPUT_TEXT=$(echo "$TOOL_RESPONSE" | jq -r '.stdout // empty' 2>/dev/null || echo "")
    ;;
  Write|Edit)
    # File operations — scan the content that was written
    OUTPUT_TEXT=$(echo "$TOOL_INPUT" | jq -r '.content // empty' 2>/dev/null || echo "")
    ;;
  mcp__*)
    # MCP tools — serialize response
    OUTPUT_TEXT=$(echo "$TOOL_RESPONSE" | jq -c '.' 2>/dev/null || echo "")
    ;;
esac

if [ -n "$OUTPUT_TEXT" ] && [ "$OUTPUT_TEXT" != "null" ] && [ ${#OUTPUT_TEXT} -gt 0 ]; then
  SCAN_RESPONSE=$(curl -s --max-time 5 -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    ${AUTH:+-H "Authorization: Basic $AUTH"} \
    -d "$(jq -n \
      --arg ct "$CONNECTOR_TYPE" \
      --arg msg "$OUTPUT_TEXT" \
      '{
        jsonrpc: "2.0",
        id: "hook-scan",
        method: "tools/call",
        params: {
          name: "check_output",
          arguments: {
            connector_type: $ct,
            message: $msg
          }
        }
      }')" 2>/dev/null || echo "")

  # If PII was found, add context for Claude
  if [ -n "$SCAN_RESPONSE" ]; then
    SCAN_RESULT=$(echo "$SCAN_RESPONSE" | jq -r '.result.content[0].text // empty' 2>/dev/null || echo "")
    if [ -n "$SCAN_RESULT" ]; then
      REDACTED=$(echo "$SCAN_RESULT" | jq -r '.redacted_message // empty' 2>/dev/null || echo "")
      if [ -n "$REDACTED" ] && [ "$REDACTED" != "null" ]; then
        # PII detected — inform Claude via hook output
        jq -n \
          --arg redacted "$REDACTED" \
          '{
            hookSpecificOutput: {
              hookEventName: "PostToolUse",
              additionalContext: ("WARNING: PII detected in tool output. Redacted version: " + $redacted + ". Do not expose the original PII in your response.")
            }
          }'
        exit 0
      fi
    fi
  fi
fi

# No issues — exit silently
exit 0
