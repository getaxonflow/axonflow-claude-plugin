#!/usr/bin/env bash
# PostToolUse hook — audit logging and output scanning.
# Matches the OpenClaw plugin's after_tool_call + message_sending hooks.
#
# 1. Records tool execution in AxonFlow audit trail (fire-and-forget, background)
# 2. Scans tool output for PII/secrets (synchronous — needs to return context to Claude)
#
# This script is best-effort: failures never block tool execution.
# No set -e — individual command failures are handled gracefully.

# Fail-open: if jq/curl not available, exit silently
if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
  exit 0
fi

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
AUTH="${AXONFLOW_AUTH:-}"

AUTH_HEADER=()
if [ -n "$AUTH" ]; then
  AUTH_HEADER=(-H "Authorization: Basic $AUTH")
fi

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")
TOOL_RESPONSE=$(echo "$INPUT" | jq -c '.tool_response // {}' 2>/dev/null || echo "{}")

# Skip if no tool name
if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

CONNECTOR_TYPE="claude_code.${TOOL_NAME}"

# Determine success from tool response
SUCCESS=$(echo "$TOOL_RESPONSE" | jq 'if .exitCode != null then (.exitCode == 0) elif .success != null then .success else true end' 2>/dev/null || echo "true")
ERROR_MSG=$(echo "$TOOL_RESPONSE" | jq -r '.stderr // empty' 2>/dev/null || echo "")

# Truncate large outputs for audit (character-safe, not byte-safe)
TRUNCATED_OUTPUT=$(echo "$TOOL_RESPONSE" | jq -c '.' 2>/dev/null | cut -c1-500 || echo "{}")

# 1. Record audit entry (fire-and-forget, background)
(
  curl -s --max-time 5 -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
    -d "$(jq -n \
      --arg tn "$TOOL_NAME" \
      --arg ti "$TOOL_INPUT" \
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
            input: ($ti | fromjson? // {}),
            output: {summary: $out},
            success: $success,
            error_message: $err
          }
        }
      }')" > /dev/null 2>&1
) &

# 2. Scan tool output for PII/secrets (synchronous — returns context to Claude if PII found)
OUTPUT_TEXT=""
case "$TOOL_NAME" in
  Bash)
    OUTPUT_TEXT=$(echo "$TOOL_RESPONSE" | jq -r '.stdout // empty' 2>/dev/null || echo "")
    ;;
  Write)
    OUTPUT_TEXT=$(echo "$TOOL_INPUT" | jq -r '.content // empty' 2>/dev/null || echo "")
    ;;
  Edit)
    OUTPUT_TEXT=$(echo "$TOOL_INPUT" | jq -r '.new_string // empty' 2>/dev/null || echo "")
    ;;
  NotebookEdit)
    OUTPUT_TEXT=$(echo "$TOOL_INPUT" | jq -r '.cell_content // .content // empty' 2>/dev/null || echo "")
    ;;
  mcp__*)
    OUTPUT_TEXT=$(echo "$TOOL_RESPONSE" | jq -c '.' 2>/dev/null || echo "")
    ;;
esac

if [ -n "$OUTPUT_TEXT" ] && [ "$OUTPUT_TEXT" != "null" ]; then
  SCAN_RESPONSE=$(curl -s --max-time 5 -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
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
