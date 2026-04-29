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

# Endpoint resolution per ADR-048: default to AxonFlow Community SaaS only when
# the user has not set explicit config. Any user-supplied AXONFLOW_ENDPOINT or
# AXONFLOW_AUTH is honoured untouched — no silent override.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
  ENDPOINT="https://try.getaxonflow.com"
  AXONFLOW_MODE="community-saas"
  # Test-harness override (tests/heartbeat-real-stack/). Production code
  # paths leave AXONFLOW_HARNESS unset and the endpoint stays pinned.
  if [ "${AXONFLOW_HARNESS:-}" = "1" ] && [ -n "${AXONFLOW_HARNESS_AGENT_ENDPOINT:-}" ]; then
    ENDPOINT="$AXONFLOW_HARNESS_AGENT_ENDPOINT"
  fi
else
  ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
  AXONFLOW_MODE="self-hosted"
fi
AUTH="${AXONFLOW_AUTH:-}"
REQUEST_TIMEOUT_SECONDS="${AXONFLOW_TIMEOUT_SECONDS:-8}"
export AXONFLOW_MODE

# Mode-clarity canary on stderr (NEVER stdout — stdout is the hook protocol).
# CI's mode-clarity gate parses this line and asserts it matches the actual
# outbound destination. Users can never be misled about which AxonFlow they're
# talking to.
echo "[AxonFlow] Connected to AxonFlow at ${ENDPOINT} (mode=${AXONFLOW_MODE})" >&2

# Community-SaaS bootstrap: register with try.getaxonflow.com on first run and
# load the resulting Basic-auth credential into AXONFLOW_AUTH. No-op when the
# user has set explicit config (AXONFLOW_MODE != community-saas).
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/community-saas-bootstrap.sh"
AUTH="${AXONFLOW_AUTH:-}"

# Build auth header array safely (avoids word-splitting)
AUTH_HEADER=()
if [ -n "$AUTH" ]; then
  AUTH_HEADER=(-H "Authorization: Basic $AUTH")
fi

# One-time positive disclosure when first connecting to Community SaaS. Stamp
# is separate from telemetry so the disclosure fires exactly once per install,
# independent of the 7-day heartbeat cadence.
DISCLOSURE_STAMP="${HOME}/.cache/axonflow/claude-code-plugin-disclosure-shown"
if [ "$AXONFLOW_MODE" = "community-saas" ] && [ ! -f "$DISCLOSURE_STAMP" ]; then
  mkdir -p "$(dirname "$DISCLOSURE_STAMP")" 2>/dev/null && chmod 0700 "$(dirname "$DISCLOSURE_STAMP")" 2>/dev/null
  cat <<'EOF' >&2
[AxonFlow] Connected to AxonFlow Community SaaS at https://try.getaxonflow.com.
Intended for basic testing and evaluation. For real workflows, real systems,
or sensitive data, we recommend self-hosting AxonFlow from day one:
  https://docs.getaxonflow.com/quickstart
Anonymous telemetry: weekly heartbeat. Opt out: AXONFLOW_TELEMETRY=off
EOF
  : >"$DISCLOSURE_STAMP" 2>/dev/null
fi

# Telemetry heartbeat (7-day cadence; stamp-on-delivery; in-flight gate).
# Backgrounded so it never blocks the hook protocol.
"${SCRIPT_DIR}/telemetry-ping.sh" </dev/null &
# Plugin/platform version compatibility check — fire-and-forget, runs once
# per install, warns to stderr if the plugin is below the platform's
# min_plugin_version (axonflow-enterprise#1764). Same fire-and-forget shape
# as telemetry-ping; never blocks the hook hot path.
"${SCRIPT_DIR}/version-check.sh" </dev/null &

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
    CONTENT=$(echo "$TOOL_INPUT" | jq -r '.content // empty' | cut -c1-2000)
    STATEMENT="${FILE_PATH}"$'\n'"${CONTENT}"
    ;;
  Edit)
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
    NEW_STRING=$(echo "$TOOL_INPUT" | jq -r '.new_string // empty' | cut -c1-2000)
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

# Call AxonFlow check_policy via MCP server.
#
# Issue #1545 Direction 3: fail OPEN on any network-level failure (timeout,
# DNS failure, connection refused, 5xx). Only auth/config errors reported
# by AxonFlow fail closed (see the JSONRPC_ERROR handling below).
RESPONSE=$(curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" -X POST "${ENDPOINT}/api/v1/mcp-server" \
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
    }')" 2>/dev/null)
CURL_EXIT=$?

# Any curl-level failure — timeout, DNS failure, connection refused, TCP
# reset — fails open.
if [ "$CURL_EXIT" -ne 0 ] || [ -z "$RESPONSE" ]; then
  exit 0
fi

# Check for JSON-RPC error responses and apply the fail-open / fail-closed
# policy from issue #1545 Direction 3:
#
#   Auth errors (-32001):       DENY — operator must fix AXONFLOW_AUTH
#   Method not found (-32601):  DENY — plugin version mismatch with agent
#   Invalid params (-32602):    DENY — plugin bug, operator should upgrade
#   Parse errors (-32700):      ALLOW — transient
#   Internal errors (-32603):   ALLOW — server-side fault, not operator's
#   Everything else:            ALLOW — unknown failure, default to allow
JSONRPC_ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null || echo "")
if [ -n "$JSONRPC_ERROR" ]; then
  JSONRPC_CODE=$(echo "$RESPONSE" | jq -r '.error.code // 0' 2>/dev/null || echo "0")
  case "$JSONRPC_CODE" in
    -32001|-32601|-32602)
      jq -n \
        --arg err "$JSONRPC_ERROR" \
        --arg code "$JSONRPC_CODE" \
        '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: ("AxonFlow governance blocked: " + $err + " (code " + $code + "). Fix AxonFlow configuration to restore tool access.")
          }
        }'
      exit 0
      ;;
    *)
      # Transient or server-side — fail open.
      exit 0
      ;;
  esac
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

# Plugin Batch 1 (ADR-042 + ADR-043): richer block context surfaced when
# the platform is v7.1.0+. All fields are optional; absent on older
# platforms.
DECISION_ID=$(echo "$TOOL_RESULT" | jq -r '.decision_id // empty' 2>/dev/null || echo "")
RISK_LEVEL=$(echo "$TOOL_RESULT" | jq -r '.risk_level // empty' 2>/dev/null || echo "")
OVERRIDE_AVAILABLE=$(echo "$TOOL_RESULT" | jq -r '.override_available // false' 2>/dev/null || echo "false")
OVERRIDE_EXISTING_ID=$(echo "$TOOL_RESULT" | jq -r '.override_existing_id // empty' 2>/dev/null || echo "")

if [ "$ALLOWED" = "false" ]; then
  # Record the blocked attempt in the audit trail (fire-and-forget).
  # This ensures blocked events appear in audit search and compliance reports.
  curl -s --max-time "$REQUEST_TIMEOUT_SECONDS" -X POST "${ENDPOINT}/api/v1/mcp-server" \
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

  # Return deny decision to Claude Code. Plugin Batch 1: surface richer
  # context (decision_id, risk_level, override availability) when the
  # platform provides it so the user knows how to unblock themselves.
  CONTEXT_SUFFIX=""
  if [ -n "$DECISION_ID" ]; then
    CONTEXT_SUFFIX=" [decision: $DECISION_ID"
    if [ -n "$RISK_LEVEL" ]; then
      CONTEXT_SUFFIX="$CONTEXT_SUFFIX, risk: $RISK_LEVEL"
    fi
    if [ "$OVERRIDE_AVAILABLE" = "true" ]; then
      if [ -n "$OVERRIDE_EXISTING_ID" ]; then
        CONTEXT_SUFFIX="$CONTEXT_SUFFIX, active override: $OVERRIDE_EXISTING_ID"
      else
        CONTEXT_SUFFIX="$CONTEXT_SUFFIX, override available via explain_decision MCP tool"
      fi
    fi
    CONTEXT_SUFFIX="$CONTEXT_SUFFIX]"
  fi

  jq -n \
    --arg reason "$BLOCK_REASON" \
    --arg policies "$POLICIES_EVALUATED" \
    --arg ctx "$CONTEXT_SUFFIX" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("AxonFlow policy violation: " + $reason + " (" + $policies + " policies evaluated)" + $ctx)
      }
    }'
  exit 0
fi

# Allowed — no output needed
exit 0
# CI re-trigger: 1777491394
