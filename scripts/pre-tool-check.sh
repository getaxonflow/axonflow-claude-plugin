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

# Self-hosted / Enterprise credential resolution (axonflow-claude-plugin#94).
# Keeps the hooks in parity with the inline MCP headersHelper: when running
# against a self-hosted/Enterprise agent with AXONFLOW_AUTH unset, fall back to
# ~/.config/axonflow/self-hosted-auth.json instead of the Community-SaaS
# registration (which would send a cs_<uuid> credential the Enterprise agent
# rejects with "invalid license key prefix"). Also normalizes a raw
# "<org>:<key>" AXONFLOW_AUTH to the base64 the agent expects. No-op in
# community-saas mode (the registration bootstrap owns that credential).
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/self-hosted-auth.sh"
resolve_self_hosted_auth
AUTH="${AXONFLOW_AUTH:-}"

# V1 paid Pro tier (axonflow-enterprise PR #1850): resolve the license token
# from env (AXONFLOW_LICENSE_TOKEN — wins) or ~/.config/axonflow/license-token.json
# (written by `/axonflow-login --token <AXON-...>`). When present, the plugin
# sends it as X-License-Token on every governed agent request so the agent's
# PluginClaimMiddleware enriches the request context with Pro-tier metadata
# (retention, quota, …). Free tier is unaffected — the header is simply
# absent and the middleware passes through (PluginClaimContext == nil).
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/license-token.sh"
resolve_license_token

# ADR-050 §4: every governed request to the agent carries X-Axonflow-Client
# so the agent can derive request scope (plugin) and validate it against the
# token's aud.scope via HasScope().
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/client-header.sh"

# V1 Plugin Pro upgrade-prompt envelope handling (umbrella
# axonflow-enterprise#1958). Provides axonflow_throttle_active +
# axonflow_handle_envelope_response. See scripts/upgrade-prompt.sh.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/upgrade-prompt.sh"

# Build auth header array safely (avoids word-splitting)
AUTH_HEADER=()
if [ -n "$AUTH" ]; then
  AUTH_HEADER=(-H "Authorization: Basic $AUTH")
fi
AUTH_HEADER+=(-H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}")
# X-License-Token is appended to AUTH_HEADER so it ships on every curl call
# below — both the check_policy POST and the audit_tool_call POST. PR #1850
# defined PluginClaimMiddleware; whichever routes the platform mounts it
# on will then read the header and enrich the request context. Routes
# that don't read it ignore the extra header (HTTP servers are required
# to tolerate unknown headers), so the plugin can send it consistently
# without coordinating mount points.
if [ -n "${AXONFLOW_LICENSE_TOKEN:-}" ]; then
  AUTH_HEADER+=(-H "X-License-Token: ${AXONFLOW_LICENSE_TOKEN}")
  # Mode-clarity canary extension — surface "Pro tier active" so the
  # operator sees a paid token is in play. Stamp on stderr only — stdout is
  # the hook protocol and any byte there breaks Claude Code's parser.
  echo "[AxonFlow] Pro tier active (X-License-Token configured)" >&2
fi

# Per-developer identity (issue #2754; hardened per #2836). Resolve
# AXONFLOW_USER_EMAIL (→ git fallback: repo-local then global) and, when
# present, ship it as X-User-Email so the agent attributes every governed
# request below — the check_policy POST AND the blocked/redacted
# audit_tool_call POSTs (all reuse AUTH_HEADER) — to a real developer instead
# of the synthetic "mcp-client:<org>" id. Omitted entirely when unset (no
# empty header); the agent then degrades to the synthetic id, never a hard
# NULL, and the helper emits a once-per-day stderr notice saying why.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/user-identity.sh"
resolve_user_identity
if [ -n "${AXONFLOW_USER_EMAIL_RESOLVED:-}" ]; then
  AUTH_HEADER+=(-H "X-User-Email: ${AXONFLOW_USER_EMAIL_RESOLVED}")
fi

# Per-user authorization token (axonflow-enterprise#2935, epic #2919).
# Resolve the admin-minted per-user token from env (AXONFLOW_USER_TOKEN —
# wins) or ~/.config/axonflow/user-token.json (0600-guarded) and, when
# present, ship it as X-User-Token so the platform resolves a VALIDATED
# {identity, role} for this developer instead of the least-privilege
# attribution-only fallback. Appended to AUTH_HEADER so it ships on every
# governed curl below (check_policy + the blocked/redacted audit_tool_call
# POSTs). Omitted entirely when unconfigured (no empty header) — requests
# are then byte-identical to a pre-token plugin and X-User-Email keeps its
# existing attribution role. The token value is never logged.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/user-token.sh"
resolve_user_token
if [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then
  AUTH_HEADER+=(-H "X-User-Token: ${AXONFLOW_USER_TOKEN}")
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

# Per-session identity (issue #2753). Claude Code puts session_id in the hook
# stdin JSON; forward it as X-Session-Id so audit rows carry the AI-tool session
# alongside X-User-Email. Appended to AUTH_HEADER so it ships on every governed
# curl below (check_policy + the blocked/redacted audit_tool_call POSTs). Strip
# CR/LF as a header-split guard; omitted entirely when absent. This is the ONLY
# surface that carries session_id — the .mcp.json MCP path has no per-call id.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r\n' || echo "")
if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "null" ]; then
  AUTH_HEADER+=(-H "X-Session-Id: ${SESSION_ID}")
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
    CONTENT=$(echo "$TOOL_INPUT" | jq -r '.content // empty')
    STATEMENT="${FILE_PATH}"$'\n'"${CONTENT}"
    ;;
  Edit)
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
    NEW_STRING=$(echo "$TOOL_INPUT" | jq -r '.new_string // empty')
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

# V1 Plugin Pro back-off: when a recent governed call returned a 429/403
# envelope, the throttle-until stamp suppresses outbound traffic until the
# envelope's resets_at deadline. Fall open immediately so the operator's
# tool calls aren't held up while we wait out the cap (the upgrade prompt
# was already surfaced when the throttle landed).
if axonflow_throttle_active; then
  exit 0
fi

# Call AxonFlow check_policy via MCP server.
#
# Issue #1545 Direction 3: fail OPEN on any network-level failure (timeout,
# DNS failure, connection refused, 5xx). Only auth/config errors reported
# by AxonFlow fail closed (see the JSONRPC_ERROR handling below).
#
# V1 Plugin Pro: capture HTTP status + headers + body separately so the
# envelope handler can detect 429 / 403 and stamp the throttle deadline
# before we fall through to the JSON-RPC parser.
PRECHECK_BODY=$(mktemp)
PRECHECK_HEADERS=$(mktemp)
trap 'rm -f "$PRECHECK_BODY" "$PRECHECK_HEADERS"' EXIT
HTTP_CODE=$(curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" \
  -D "$PRECHECK_HEADERS" -o "$PRECHECK_BODY" -w '%{http_code}' \
  -X POST "${ENDPOINT}/api/v1/mcp-server" \
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
if [ "$CURL_EXIT" -ne 0 ]; then
  exit 0
fi

# Detect the V1 Plugin Pro envelope on 429 / 403. When present, the helper
# stamps throttle-until + emits the upgrade prompt to stderr, and we fall
# open (Free-tier without policy enforcement is the natural degraded state
# until the cap clears).
if axonflow_handle_envelope_response "$HTTP_CODE" "$PRECHECK_BODY" "$PRECHECK_HEADERS"; then
  exit 0
fi

# HTTP 401 — invalid/expired credentials. Stamp a 5-minute throttle so the
# next ~150 hook fires short-circuit locally instead of generating a fresh
# 401 each. Closes axonflow-enterprise#2275 (716 × 401 in 24h from a single
# source IP — every pre-tool-check + post-tool-audit hook re-fired because
# 401 was not envelope-bearing and the existing handler returned 1 for
# anything other than 429/403, leaving the script to fall through with no
# back-off).
#
# Carve-out for JSON-RPC -32001: when the response is HTTP 401 AND the body
# is a JSON-RPC error with `error.code == -32001`, route through the
# fail-closed (deny) branch below instead of the throttle path. Preserves
# the pre-#2275 deny semantics for the documented -32001 auth-error contract
# (issue #1545 Direction 3) — operators with persistent misconfiguration
# see a deny decision in Claude Code rather than 5 minutes of silent fall-
# open. -32001 is only emitted by the agent's MCP handler when auth is
# structurally wrong (bad token, wrong tenant), so the throttle's value
# (back off from a tight retry loop) doesn't apply and the deny's value
# (operator sees the failure immediately) does.
JSONRPC_CODE_FOR_AUTH=$(jq -r '.error.code // empty' "$PRECHECK_BODY" 2>/dev/null)
if [ "$JSONRPC_CODE_FOR_AUTH" != "-32001" ]; then
  if axonflow_handle_auth_failure "$HTTP_CODE" "$PRECHECK_BODY" "$PRECHECK_HEADERS"; then
    exit 0
  fi
fi

RESPONSE=$(cat "$PRECHECK_BODY")
if [ -z "$RESPONSE" ]; then
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
    -32001)
      # Auth error. The agent rejected the policy check because no valid
      # credential reached it — almost always a self-hosted / Enterprise
      # (in-VPC) agent that requires HTTP Basic auth, with AXONFLOW_AUTH
      # unset or wrong. Fail closed (default) so an unauthenticated session
      # can't silently bypass governance — but the deny reason MUST name the
      # exact env vars, or the operator is left guessing (the difference
      # between a 30-second fix and the cryptic "axonflow failed / OAuth
      # 404" dead-end).
      #
      # Break-glass: AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1 lets an operator keep
      # working while they fix the credential, at the cost of running
      # ungoverned. OFF by default; emits a loud stderr warning every time
      # it fires — never a silent weakening of the posture.
      if [ "${AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR:-}" = "1" ] || [ "${AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR:-}" = "true" ]; then
        echo "[AxonFlow] WARNING: auth error from ${ENDPOINT} (${JSONRPC_ERROR}); AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR is set, so this tool call is ALLOWED WITHOUT GOVERNANCE. Set AXONFLOW_AUTH=base64(org_id:license_key) and unset this break-glass to restore enforcement." >&2
        exit 0
      fi
      # #2935: when a per-user token was sent, name it as a likely cause —
      # the platform fails closed on a presented-but-invalid X-User-Token
      # (expired, revoked, wrong org), and the generic "fix AXONFLOW_AUTH"
      # guidance would send the operator down the wrong path.
      USER_TOKEN_HINT=""
      if [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then
        USER_TOKEN_HINT=" A per-user token is configured (AXONFLOW_USER_TOKEN / user-token.json) and was sent as X-User-Token — if it is expired, revoked, or minted for a different org, the platform rejects the request; ask your admin to rotate it, or remove it to fall back to shared-credential attribution."
      fi
      jq -n \
        --arg err "$JSONRPC_ERROR" \
        --arg endpoint "$ENDPOINT" \
        --arg ut_hint "$USER_TOKEN_HINT" \
        '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: ("AxonFlow governance is fail-closed: the agent at " + $endpoint + " rejected the policy check with an authentication error (\"" + $err + "\", code -32001), so this tool call is blocked. This is a self-hosted / Enterprise (in-VPC) agent that requires credentials. Fix: set AXONFLOW_ENDPOINT to your agent URL and AXONFLOW_AUTH to base64(org_id:license_key) — e.g. export AXONFLOW_AUTH=$(printf %s \"<org_id>:<license_key>\" | base64) — then restart Claude Code." + $ut_hint + " Docs: https://docs.getaxonflow.com/docs/integration/claude-code#self-hosted--enterprise-authentication . Break-glass to keep working ungoverned while you fix it: export AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1 (not recommended).")
          }
        }'
      exit 0
      ;;
    -32601|-32602)
      # Method not found / invalid params — plugin/agent version mismatch or
      # a plugin bug. Fail closed; the operator should upgrade.
      jq -n \
        --arg err "$JSONRPC_ERROR" \
        --arg code "$JSONRPC_CODE" \
        '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: ("AxonFlow governance blocked: " + $err + " (code " + $code + "). This usually means the plugin and the AxonFlow agent are on incompatible versions — upgrade the plugin or the agent so the MCP method set matches, then restart Claude Code.")
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

# Issue #2746: requires_redaction path. When check_policy returns
# requires_redaction:true (PII under a redact-action policy), deny the tool
# call before it executes and give Claude the masked content to retry with.
# This prevents the first Write from landing raw PII on disk.
REQUIRES_REDACTION=$(echo "$TOOL_RESULT" | jq -r 'if .requires_redaction == true then "true" else "false" end' 2>/dev/null || echo "false")
REDACTED_STATEMENT=$(echo "$TOOL_RESULT" | jq -r '.redacted_statement // empty' 2>/dev/null || echo "")

if [ "$REQUIRES_REDACTION" = "true" ] && [ -n "$REDACTED_STATEMENT" ]; then
  # Write and Edit both build STATEMENT as FILE_PATH\nCONTENT so we strip the
  # path header before handing the masked body to Claude as additionalContext.
  # Fall back to the full redacted_statement if the agent returns content-only
  # (no newline separator) — tail -n +2 would otherwise produce empty output.
  REDACTED_CONTENT="$REDACTED_STATEMENT"
  if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
    REDACTED_CONTENT=$(printf '%s' "$REDACTED_STATEMENT" | tail -n +2)
    if [ -z "$REDACTED_CONTENT" ]; then
      REDACTED_CONTENT="$REDACTED_STATEMENT"
    fi
  fi

  # Audit the redaction event (fire-and-forget) so it appears in compliance
  # reports alongside blocked events. Statement omitted — it contains raw PII.
  curl -s --max-time "$REQUEST_TIMEOUT_SECONDS" -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
    -d "$(jq -n \
      --arg tn "$TOOL_NAME" \
      --arg policies "$POLICIES_EVALUATED" \
      '{
        jsonrpc: "2.0",
        id: "hook-audit-redacted",
        method: "tools/call",
        params: {
          name: "audit_tool_call",
          arguments: {
            tool_name: $tn,
            tool_type: "claude_code",
            input: {statement: "[redacted]"},
            output: {policy_decision: "redacted", policies_evaluated: $policies},
            success: false,
            error_message: "PII detected — retry with redacted content"
          }
        }
      }')" > /dev/null 2>&1 &

  jq -n \
    --arg content "$REDACTED_CONTENT" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "AxonFlow detected PII in the tool input. Please retry using the redacted version provided in additionalContext.",
        additionalContext: ("AxonFlow redacted PII from the input. Use this version instead:\n\n" + $content)
      }
    }'
  exit 0
fi

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
