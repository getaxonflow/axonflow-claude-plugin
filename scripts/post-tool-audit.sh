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

# Endpoint resolution per ADR-048: default to AxonFlow Community SaaS only when
# the user has not set explicit config. Mirrors pre-tool-check.sh exactly so the
# two hooks always agree on which AxonFlow they're talking to.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
  ENDPOINT="https://try.getaxonflow.com"
  AXONFLOW_MODE="community-saas"
else
  ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
  AXONFLOW_MODE="self-hosted"
fi
export AXONFLOW_MODE
REQUEST_TIMEOUT_SECONDS="${AXONFLOW_TIMEOUT_SECONDS:-5}"

# Bootstrap the Community-SaaS credential if needed. No-op in self-hosted mode.
# Pre-tool-check ran first and likely already wrote the registration file; this
# is just loading it. Mode-clarity log line is intentionally NOT repeated here —
# pre-tool-check fires it once per hook invocation.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/community-saas-bootstrap.sh"
AUTH="${AXONFLOW_AUTH:-}"

# Self-hosted / Enterprise credential resolution (axonflow-claude-plugin#94) —
# mirror pre-tool-check.sh so both hooks and the inline MCP headersHelper agree
# on the credential. Falls back to ~/.config/axonflow/self-hosted-auth.json on
# a self-hosted/Enterprise agent when AXONFLOW_AUTH is unset, and normalizes a
# raw "<org>:<key>" value to base64. No-op in community-saas mode.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/self-hosted-auth.sh"
resolve_self_hosted_auth
AUTH="${AXONFLOW_AUTH:-}"

# V1 paid Pro tier (axonflow-enterprise PR #1850): match pre-tool-check's
# header policy so the audit + scan calls also surface the X-License-Token.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/license-token.sh"
resolve_license_token

# ADR-050 §4: X-Axonflow-Client identifies the calling plugin so the agent
# can derive request scope (plugin) and validate against the token's aud.scope.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/client-header.sh"

# V1 Plugin Pro upgrade-prompt envelope handling (umbrella
# axonflow-enterprise#1958).
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/upgrade-prompt.sh"

# When a recent governed call landed on a Free-tier cap, the throttle file
# tells us to stop sending traffic until the deadline. Audit + scan are both
# best-effort — falling open here is correct (the upgrade prompt was
# already surfaced when the throttle landed).
if axonflow_throttle_active; then
  exit 0
fi

AUTH_HEADER=()
if [ -n "$AUTH" ]; then
  AUTH_HEADER=(-H "Authorization: Basic $AUTH")
fi
AUTH_HEADER+=(-H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}")
# ADR-065 capability handshake (axonflow-enterprise#3763). Declares what this
# enforcement point can discharge, so the platform refuses to hand it a
# mandatory obligation it has said it cannot carry out.
#
# Added ONLY when non-empty. A header that is PRESENT with an empty value is
# MALFORMED to the platform and refuses the request, which an ABSENT header
# does not - so an unconditional -H here would 400 every unconfigured install.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/pep-handshake.sh"
if [ -n "${AXONFLOW_PEP_HANDSHAKE:-}" ]; then
  AUTH_HEADER+=(-H "X-Axonflow-PEP-Handshake: ${AXONFLOW_PEP_HANDSHAKE}")
fi
if [ -n "${AXONFLOW_LICENSE_TOKEN:-}" ]; then
  AUTH_HEADER+=(-H "X-License-Token: ${AXONFLOW_LICENSE_TOKEN}")
fi

# Per-developer identity (issue #2754; hardened per #2836) — mirror
# pre-tool-check.sh so the post-tool audit_tool_call POST AND the check_output
# scan below (both reuse AUTH_HEADER) attribute the row to the real developer
# via X-User-Email. Omitted entirely when unset (no empty header); the helper
# emits a once-per-day stderr notice on the identity-absent path.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/user-identity.sh"
resolve_user_identity
if [ -n "${AXONFLOW_USER_EMAIL_RESOLVED:-}" ]; then
  AUTH_HEADER+=(-H "X-User-Email: ${AXONFLOW_USER_EMAIL_RESOLVED}")
fi

# Per-user authorization token (axonflow-enterprise#2935, epic #2919) —
# mirror pre-tool-check.sh so the audit_tool_call POST AND the check_output
# scan below (both reuse AUTH_HEADER) carry X-User-Token and the platform
# resolves a VALIDATED {identity, role} for this developer. Omitted entirely
# when unconfigured (no empty header); the token value is never logged.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/user-token.sh"
resolve_user_token
if [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then
  AUTH_HEADER+=(-H "X-User-Token: ${AXONFLOW_USER_TOKEN}")
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

# Per-session identity (issue #2753) — mirror pre-tool-check.sh. session_id from
# the hook stdin JSON is forwarded as X-Session-Id on the audit_tool_call +
# check_output curls (both reuse AUTH_HEADER). CR/LF stripped; omitted when absent.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r\n' || echo "")
if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "null" ]; then
  AUTH_HEADER+=(-H "X-Session-Id: ${SESSION_ID}")
fi

CONNECTOR_TYPE="claude_code.${TOOL_NAME}"

# Determine success from tool response
SUCCESS=$(echo "$TOOL_RESPONSE" | jq 'if .exitCode != null then (.exitCode == 0) elif .success != null then .success else true end' 2>/dev/null || echo "true")
ERROR_MSG=$(echo "$TOOL_RESPONSE" | jq -r '.stderr // empty' 2>/dev/null || echo "")

# Truncate large outputs for audit (character-safe, not byte-safe)
TRUNCATED_OUTPUT=$(echo "$TOOL_RESPONSE" | jq -c '.' 2>/dev/null | cut -c1-500 || echo "{}")

# 1. Record audit entry (fire-and-forget, background)
(
  curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" -X POST "${ENDPOINT}/api/v1/mcp-server" \
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
            caller_name: "claude_code",
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
    # If stdout is empty but command contains a redirect (echo ... > file),
    # scan the command itself — the PII is in the input, not the output.
    if [ -z "$OUTPUT_TEXT" ] || [ "$OUTPUT_TEXT" = "null" ]; then
      COMMAND=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null || echo "")
      if echo "$COMMAND" | grep -qE '>>?\s*\S' ; then
        OUTPUT_TEXT="$COMMAND"
      fi
    fi
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
  SCAN_BODY=$(mktemp)
  SCAN_HEADERS=$(mktemp)
  trap 'rm -f "$SCAN_BODY" "$SCAN_HEADERS"' EXIT
  SCAN_HTTP=$(curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" \
    -D "$SCAN_HEADERS" -o "$SCAN_BODY" -w '%{http_code}' \
    -X POST "${ENDPOINT}/api/v1/mcp-server" \
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
      }')" 2>/dev/null) || SCAN_HTTP=""

  # V1 Plugin Pro: stamp throttle + nudge operator on envelope responses.
  # Caller falls open whether or not the envelope was detected.
  if axonflow_handle_envelope_response "$SCAN_HTTP" "$SCAN_BODY" "$SCAN_HEADERS"; then
    exit 0
  fi
  # HTTP 401 on the scan call — invalid/expired credentials. Same throttle
  # path as pre-tool-check: stamp 5-minute cooldown + once-per-day nudge,
  # then fall open. Closes axonflow-enterprise#2275 (auth-storm retry loop
  # against /api/v1/audit/tool-call).
  if axonflow_handle_auth_failure "$SCAN_HTTP" "$SCAN_BODY" "$SCAN_HEADERS"; then
    exit 0
  fi
  SCAN_RESPONSE=$(cat "$SCAN_BODY" 2>/dev/null || echo "")

  # If PII was found, add context for Claude
  if [ -n "$SCAN_RESPONSE" ]; then
    SCAN_RESULT=$(echo "$SCAN_RESPONSE" | jq -r '.result.content[0].text // empty' 2>/dev/null || echo "")
    if [ -n "$SCAN_RESULT" ]; then
      REDACTED=$(echo "$SCAN_RESULT" | jq -r '.redacted_message // empty' 2>/dev/null || echo "")
      POLICIES_FOUND=$(echo "$SCAN_RESULT" | jq -r '.policies_evaluated // 0' 2>/dev/null || echo "0")
      ALLOWED=$(echo "$SCAN_RESULT" | jq -r '.allowed // true' 2>/dev/null || echo "true")

      if [ -n "$REDACTED" ] && [ "$REDACTED" != "null" ]; then
        # PII detected in tool output. PostToolUse hooks cannot transform
        # the original output — we can only instruct Claude not to expose
        # the raw PII in its response to the user.
        jq -n \
          --arg redacted "$REDACTED" \
          --arg policies "$POLICIES_FOUND" \
          '{
            hookSpecificOutput: {
              hookEventName: "PostToolUse",
              additionalContext: ("GOVERNANCE ALERT: PII/sensitive data detected in tool output (" + $policies + " policies evaluated). You MUST use this redacted version instead of the original: " + $redacted)
            }
          }'
        exit 0
      elif [ "$ALLOWED" = "false" ]; then
        # Output blocked by policy (not just PII redaction)
        BLOCK_REASON=$(echo "$SCAN_RESULT" | jq -r '.block_reason // "Policy violation in tool output"' 2>/dev/null || echo "")
        jq -n \
          --arg reason "$BLOCK_REASON" \
          '{
            hookSpecificOutput: {
              hookEventName: "PostToolUse",
              additionalContext: ("GOVERNANCE ALERT: Tool output blocked by policy: " + $reason + ". Do not use or reference the blocked output in your response.")
            }
          }'
        exit 0
      fi
    fi
  fi
fi

# No issues — exit silently
exit 0
