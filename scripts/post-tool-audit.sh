#!/usr/bin/env bash
# PostToolUse hook — audit logging and output scanning.
# Matches the OpenClaw plugin's after_tool_call + message_sending hooks.
#
# 1. Records tool execution in AxonFlow audit trail (fire-and-forget, background)
# 2. Scans tool output for PII/secrets (synchronous — needs to return context to Claude)
#
# PostToolUse always exits 0 — it never blocks; the tool already ran. When the
# output could not be checked it says so, one of two ways, reading the same
# status table as pre-tool-check.sh (scripts/lib/failure-posture.sh):
#   - an answer that refused the check (a 401 or its cooldown, a 429 or a
#     request-rate limit stamp, a 3xx, a 4xx other than 408 without a JSON-RPC
#     answer, a JSON-RPC error other than -32603 / -32700, a result without a
#     decision), or a check request that could not be built -> a GOVERNANCE
#     ALERT in additionalContext telling Claude not to use the output (with
#     AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR set, a -32001 answer's alert names it);
#   - no usable answer (unreachable, timeout, 408, 5xx, JSON-RPC -32603 /
#     -32700, an empty or unreadable body, jq or curl missing) ->
#     AXONFLOW_FAIL_MODE decides: unset, empty or "open" passes the output with
#     a notice in systemMessage, which Claude Code shows the user; any other
#     value raises the same GOVERNANCE ALERT.
# No set -e — individual command failures are handled gracefully.

# The script's directory from builtins only: this runs before the dependency
# check below, on a PATH that may hold nothing but bash.
# The time budget (scripts/lib/failure-posture.sh) counts bash's SECONDS from
# here. SECONDS exported by the calling environment would otherwise move it:
# a large value exhausts the budget before the check, a negative one lifts it.
SECONDS=0

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
if [ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="."
fi
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

# _axonflow_json_string <text>
#   The text as a JSON string. jq when it is installed; without it, by hand:
#   backslashes and double quotes escaped and control characters dropped, so
#   the document stays valid (the text is this script's own wording).
_axonflow_json_string() {
  if command -v jq &>/dev/null; then
    printf '%s' "$1" | jq -Rs .
  else
    # Builtins only: this runs when jq is missing, on a PATH that may hold
    # nothing else. Backslashes and double quotes are escaped and control
    # characters dropped, so the document stays valid.
    local s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
      c="${s:i:1}"
      case "$c" in
        \\) out="${out}\\\\" ;;
        '"') out="${out}\\\"" ;;
        [[:cntrl:]]) ;;
        *) out="${out}${c}" ;;
      esac
    done
    printf '"%s"' "$out"
  fi
}

# Emit a PostToolUse governance alert and stop.
axonflow_post_alert() {
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}\n' "$(_axonflow_json_string "$1")"
  exit 0
}

# The output could not be checked: tell Claude not to use it, saying why.
axonflow_post_unchecked() {
  axonflow_post_alert "GOVERNANCE ALERT: AxonFlow could not check this tool output ($1). Do not use or reference the output in your response until it can be checked."
}

# The failure-posture table this hook reads. Without it the hook cannot tell a
# check from a refusal, so Claude is told not to use the output.
# shellcheck source=./lib/failure-posture.sh
if ! . "${SCRIPT_DIR}/lib/failure-posture.sh" 2>/dev/null; then
  axonflow_post_unchecked "the AxonFlow plugin install is incomplete: scripts/lib/failure-posture.sh is missing or unreadable"
fi

# The output could not be checked because no usable answer arrived.
# AXONFLOW_FAIL_MODE decides: unset, empty or "open" (any case) passes the
# output with a notice the user sees (systemMessage; Claude Code does not show
# a hook's stderr on exit 0, and the same line goes there for logs); any other
# value tells Claude not to use it.
axonflow_post_ungoverned() {
  if ! axonflow_fail_mode_open; then
    axonflow_post_unchecked "$1, and AXONFLOW_FAIL_MODE is not open"
  fi
  local notice="[AxonFlow] GOVERNANCE UNAVAILABLE: $1. This tool output was NOT checked. Set AXONFLOW_FAIL_MODE=closed to withhold unchecked output from the model."
  echo "$notice" >&2
  printf '{"systemMessage":%s}\n' "$(_axonflow_json_string "$notice")"
  exit 0
}

# The hook cannot read the tool call or reach AxonFlow without these.
if ! command -v jq &>/dev/null; then
  axonflow_post_ungoverned "the AxonFlow hook needs jq, which is not installed"
fi
if ! command -v curl &>/dev/null; then
  axonflow_post_ungoverned "the AxonFlow hook needs curl, which is not installed"
fi

# Endpoint resolution per ADR-048: default to AxonFlow Community SaaS only when
# the user has not set explicit config. Mirrors pre-tool-check.sh exactly so the
# two hooks always agree on which AxonFlow they're talking to.
if [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
  ENDPOINT="https://try.getaxonflow.com"
  AXONFLOW_MODE="community-saas"
  # Test-harness override, as in pre-tool-check.sh: production code paths leave
  # AXONFLOW_HARNESS unset and the endpoint stays pinned
  # (tests/test-hooks.sh, the harness community-saas legs).
  if [ "${AXONFLOW_HARNESS:-}" = "1" ] && [ -n "${AXONFLOW_HARNESS_AGENT_ENDPOINT:-}" ]; then
    ENDPOINT="$AXONFLOW_HARNESS_AGENT_ENDPOINT"
  fi
else
  ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
  AXONFLOW_MODE="self-hosted"
fi
export AXONFLOW_MODE
# The configured per-request timeout (a positive integer; anything else is the
# default). The scan itself gets no more than the hook's time budget leaves.
CONFIGURED_TIMEOUT_SECONDS="${AXONFLOW_TIMEOUT_SECONDS:-5}"
case "$CONFIGURED_TIMEOUT_SECONDS" in ''|*[!0-9]*|0) CONFIGURED_TIMEOUT_SECONDS=5 ;; esac
REQUEST_TIMEOUT_SECONDS="$CONFIGURED_TIMEOUT_SECONDS"

# Bootstrap the Community-SaaS credential if needed. No-op in self-hosted mode.
# Pre-tool-check ran first and likely already wrote the registration file; this
# is just loading it. Mode-clarity log line is intentionally NOT repeated here —
# pre-tool-check fires it once per hook invocation.
_AXONFLOW_REGISTER_MAX_TIME=$(axonflow_budget_timeout 5 4)
# Only this run's bootstrap may define its cleanup: nothing of that name from
# the environment (an exported shell function) is ever called.
unset _AXONFLOW_BOOTSTRAP_TRAP
unset -f _axonflow_bootstrap_cleanup_on_exit 2>/dev/null
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
# axonflow-enterprise#1958) and the shared throttle-until stamp.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/upgrade-prompt.sh"

AUTH_ALERT="GOVERNANCE ALERT: AxonFlow could not check this tool output (the AxonFlow agent rejected authentication, HTTP 401). Do not use or reference the output in your response until the credential is fixed and it can be checked."

# A recent governed call stamped the shared throttle-until file, and the hook
# answers locally. The output cannot be checked while a gating stamp holds, so
# Claude is told not to use it: the 401 cooldown (auth_failure) or a
# request-rate limit written less than 300 seconds ago (ruled 2026-09-14).
# Any other stamp gates nothing (scripts/upgrade-prompt.sh, the stamp rules).
case "$(axonflow_governed_stamp)" in
  auth_failure)
    echo "[AxonFlow] $(axonflow_auth_cooldown_note)" >&2
    axonflow_post_alert "$AUTH_ALERT"
    ;;
  limit)
    axonflow_post_alert "$AXONFLOW_LIMIT_POST_ALERT"
    ;;
esac

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

# 1. Record audit entry (fire-and-forget, background). The record is built from
# the hook input on stdin, so no field of any size becomes a command-line
# argument; the output summary is the first 500 characters of the response.
#
# `success` is sent only when the host said how the tool ended: a numeric
# exitCode (0 is success) or a boolean success in the tool_response. Claude
# Code's Bash, Write and Edit responses carry neither (captured from Claude
# Code 2.1.273, tests/fixtures/claude-code-hook-json/), so their records carry
# no success field rather than claiming one; the platform stores an absent
# success as unknown (POST /api/v1/audit/tool-call requires only tool_name).
# Community SaaS with no credential after the bootstrap (the registration did
# not complete: unreachable, refused, rate limited, or out of time): there is
# nothing to authenticate the check with, so it is no usable answer. No request
# is sent (neither the audit record nor the scan; either could only be refused
# as a 401, which would stamp a cooldown), and no stamp is written.
if [ "${AXONFLOW_MODE:-}" = "community-saas" ] && [ -z "$AUTH" ]; then
  axonflow_post_ungoverned "the AxonFlow Community SaaS registration did not succeed, so there is no credential to ask the AxonFlow agent at ${ENDPOINT} with (the agent was not asked)"
fi

# The audit call runs in the background, so it holds none of the hook's
# output open (a host reading the hook's stdout to its end would otherwise
# wait for it), and it gets no more than the hook's time budget leaves.
AUDIT_TIMEOUT_SECONDS=$(axonflow_budget_timeout "$CONFIGURED_TIMEOUT_SECONDS" 1)
if [ "$AUDIT_TIMEOUT_SECONDS" -ge 1 ]; then
(
  printf '%s' "$INPUT" | jq -c \
      '(.tool_response // {}) as $r
      | {
        jsonrpc: "2.0",
        id: "hook-audit",
        method: "tools/call",
        params: {
          name: "audit_tool_call",
          arguments: ({
            tool_name: .tool_name,
            caller_name: "claude_code",
            tool_type: "claude_code",
            input: (.tool_input // {}),
            output: {summary: ($r | tojson | .[0:500])},
            error_message: (if ($r | type) == "object" then ($r.stderr // "") else "" end)
          } + (if ($r | type) == "object" and ($r.exitCode | type) == "number" then {success: ($r.exitCode == 0)}
               elif ($r | type) == "object" and ($r.success | type) == "boolean" then {success: $r.success}
               else {} end))
        }
      }' 2>/dev/null | curl -sS --max-time "$AUDIT_TIMEOUT_SECONDS" -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
    --data-binary @- > /dev/null 2>&1
) >/dev/null 2>&1 &
fi

# 2. Scan tool output for PII/secrets (synchronous — returns context to Claude if PII found)
OUTPUT_TEXT=""
case "$TOOL_NAME" in
  Bash)
    # Claude Code sends a Bash tool_response as an object whose output is in
    # .stdout and .stderr (captured from Claude Code 2.1.273: stdout, stderr, interrupted,
    # isImage, noOutputExpected; see tests/fixtures/claude-code-hook-json/).
    # stdout and stderr both reach the model, so both are scanned.
    OUTPUT_TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_response | if type == "string" then . elif type == "object" then ([.stdout, .stderr] | map(select(type == "string" and . != "")) | join("\n")) else empty end' 2>/dev/null || echo "")
    # A command with a redirect (echo ... > file) carries its data in the
    # input, not the output, so the command is scanned too, ahead of whatever
    # output the command printed.
    COMMAND=$(printf '%s' "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null || echo "")
    if grep -qE '>>?\s*\S' <<<"$COMMAND"; then
      if [ -z "$OUTPUT_TEXT" ] || [ "$OUTPUT_TEXT" = "null" ]; then
        OUTPUT_TEXT="$COMMAND"
      else
        OUTPUT_TEXT="${COMMAND}
${OUTPUT_TEXT}"
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
    OUTPUT_TEXT=$(echo "$TOOL_INPUT" | jq -r '.new_source // .cell_content // .content // empty' 2>/dev/null || echo "")
    ;;
  mcp__*)
    OUTPUT_TEXT=$(echo "$TOOL_RESPONSE" | jq -c '.' 2>/dev/null || echo "")
    ;;
esac

if [ -n "$OUTPUT_TEXT" ] && [ "$OUTPUT_TEXT" != "null" ]; then
  SCAN_REQUEST=$(mktemp)
  SCAN_BODY=$(mktemp)
  SCAN_HEADERS=$(mktemp)
  trap 'rm -f "$SCAN_REQUEST" "$SCAN_BODY" "$SCAN_HEADERS"; axonflow_bootstrap_cleanup' EXIT

  # The output reaches jq on stdin and the body reaches curl as a file, never as
  # a command-line argument: an argument has a size limit, and the tool decides
  # how much output there is. If the request cannot be built, the output was
  # never checked, and Claude is told not to use it.
  if ! printf '%s' "$OUTPUT_TEXT" | jq -Rsc --arg ct "$CONNECTOR_TYPE" \
      '{
        jsonrpc: "2.0",
        id: "hook-scan",
        method: "tools/call",
        params: {
          name: "check_output",
          arguments: {
            connector_type: $ct,
            message: .
          }
        }
      }' > "$SCAN_REQUEST" 2>/dev/null || [ ! -s "$SCAN_REQUEST" ]; then
    axonflow_post_unchecked "the check request could not be built"
  fi

  REQUEST_TIMEOUT_SECONDS=$(axonflow_budget_timeout "$CONFIGURED_TIMEOUT_SECONDS" 1)
  if [ "$REQUEST_TIMEOUT_SECONDS" -lt 1 ]; then
    axonflow_post_ungoverned "the hook's ${_AXONFLOW_HOOK_BUDGET_SECONDS}-second time budget ran out before the AxonFlow agent at ${ENDPOINT} could be asked"
  fi
  SCAN_HTTP=$(curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" \
    -D "$SCAN_HEADERS" -o "$SCAN_BODY" -w '%{http_code}' \
    -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
    --data-binary @"$SCAN_REQUEST" 2>/dev/null)
  SCAN_CURL_EXIT=$?

  # No answer arrived: timeout, DNS failure, connection refused, TCP reset.
  if [ "$SCAN_CURL_EXIT" -ne 0 ]; then
    axonflow_post_ungoverned "the AxonFlow agent at ${ENDPOINT} could not be reached (curl exit ${SCAN_CURL_EXIT})"
  fi

  # V1 Plugin Pro: stamp throttle + show the upgrade prompt on envelope
  # responses, and tell the model the output could not be checked.
  if axonflow_handle_envelope_response "$SCAN_HTTP" "$SCAN_BODY" "$SCAN_HEADERS"; then
    axonflow_post_alert "$AXONFLOW_LIMIT_POST_ALERT"
  fi
  SCAN_RESPONSE=$(cat "$SCAN_BODY" 2>/dev/null || echo "")

  # The status of an answer the lines above did not settle, read by the table
  # pre-tool-check.sh reads (scripts/lib/failure-posture.sh). The platform's
  # words are cleaned of control characters and quoted as the platform's.
  SCAN_TEXT=$(axonflow_platform_text "$SCAN_RESPONSE")
  SCAN_SAID="${SCAN_TEXT:+; AxonFlow said: \"$SCAN_TEXT\"}"

  # HTTP 401. With AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR set, a -32001 answer is
  # alerted naming the switch and stamps no cooldown (the pre hook runs the
  # call under it). Every other 401 stamps the cooldown (the helper; 300
  # seconds by default) so a tight retry loop can't keep firing the same
  # auth-failing scan request (axonflow-enterprise#2275), and Claude is told
  # not to use the unchecked output.
  if [ "$SCAN_HTTP" = "401" ]; then
    if [ "$(axonflow_jsonrpc_error_code "$SCAN_RESPONSE")" = "-32001" ] && { [ "${AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR:-}" = "1" ] || [ "${AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR:-}" = "true" ]; }; then
      axonflow_post_unchecked "the AxonFlow agent rejected authentication, HTTP 401 code -32001${SCAN_SAID}; AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR is set, so tool calls run WITHOUT GOVERNANCE"
    fi
    axonflow_handle_auth_failure "$SCAN_HTTP" "$SCAN_BODY" "$SCAN_HEADERS"
    echo "[AxonFlow] $(axonflow_auth_cooldown_note)" >&2
    axonflow_post_alert "$AUTH_ALERT"
  fi

  SCAN_IS_JSONRPC=$(axonflow_is_jsonrpc_answer "$SCAN_RESPONSE")
  case "$(axonflow_status_class "$SCAN_HTTP" "$SCAN_IS_JSONRPC")" in
    answer) ;;
    limit)
      axonflow_post_unchecked "the AxonFlow agent answered HTTP 429, a request limit${SCAN_SAID}"
      ;;
    too_large)
      axonflow_post_unchecked "the AxonFlow agent refused the check as too large, HTTP 413${SCAN_SAID}"
      ;;
    refused)
      axonflow_post_unchecked "the AxonFlow agent refused the request, HTTP ${SCAN_HTTP}${SCAN_SAID}"
      ;;
    *)
      axonflow_post_ungoverned "the AxonFlow agent answered HTTP ${SCAN_HTTP}${SCAN_SAID}"
      ;;
  esac

  if [ -z "$SCAN_RESPONSE" ]; then
    axonflow_post_ungoverned "the AxonFlow agent answered HTTP ${SCAN_HTTP} with an empty body"
  fi

  # A body that is not exactly one JSON document is no usable answer: a result
  # and an error in one body would each be read by a different line below.
  if ! axonflow_one_json_document "$SCAN_RESPONSE"; then
    axonflow_post_ungoverned "the AxonFlow agent's answer (HTTP ${SCAN_HTTP}) was not one JSON document"
  fi

  # A JSON-RPC error is not a check. Server-internal and parse errors are no
  # usable answer; every other code (auth, method, params, unknown), and an
  # error object with no numeric code or no message, refused it.
  SCAN_RPC_CODE=$(axonflow_jsonrpc_error_code "$SCAN_RESPONSE")
  if [ -n "$SCAN_RPC_CODE" ]; then
    SCAN_RPC_ERROR="${SCAN_TEXT:-no message}"
    case "$SCAN_RPC_CODE" in
      -32603|-32700)
        axonflow_post_ungoverned "the AxonFlow agent answered a server error (code ${SCAN_RPC_CODE}; AxonFlow said: \"${SCAN_RPC_ERROR}\")"
        ;;
      -32001)
        if [ "${AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR:-}" = "1" ] || [ "${AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR:-}" = "true" ]; then
          axonflow_post_unchecked "the AxonFlow agent refused the check, code -32001; AxonFlow said: \"${SCAN_RPC_ERROR}\"; AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR is set, so tool calls run WITHOUT GOVERNANCE"
        fi
        axonflow_post_unchecked "the AxonFlow agent refused the check, code -32001; AxonFlow said: \"${SCAN_RPC_ERROR}\""
        ;;
      *)
        axonflow_post_unchecked "the AxonFlow agent refused the check, code ${SCAN_RPC_CODE}; AxonFlow said: \"${SCAN_RPC_ERROR}\""
        ;;
    esac
  fi

  SCAN_RESULT=$(echo "$SCAN_RESPONSE" | jq -r '.result.content[0].text // empty' 2>/dev/null || echo "")
  if [ -z "$SCAN_RESULT" ]; then
    # A JSON-RPC result with no tool result carries no decision.
    if echo "$SCAN_RESPONSE" | jq -e 'has("result")' >/dev/null 2>&1; then
      axonflow_post_unchecked "the AxonFlow agent returned no decision"
    fi
    axonflow_post_ungoverned "the AxonFlow agent's answer (HTTP ${SCAN_HTTP}) was not a check result"
  fi

  # A result flagged isError, or one without a boolean `allowed`, is not a
  # decision (ruled 2026-09-14). The Free-tier cap answers this way with its
  # upgrade envelope as the text: the handler still shows the prompt.
  SCAN_IS_ERROR=$(echo "$SCAN_RESPONSE" | jq -r 'if .result.isError == true then "true" else "false" end' 2>/dev/null || echo "false")
  SCAN_HAS_DECISION=$(echo "$SCAN_RESULT" | jq -r 'if (.allowed | type) == "boolean" then "true" else "false" end' 2>/dev/null || echo "false")
  if [ "$SCAN_IS_ERROR" = "true" ] || [ "$SCAN_HAS_DECISION" != "true" ]; then
    if axonflow_handle_envelope_text "$SCAN_RESULT"; then
      axonflow_post_alert "$AXONFLOW_LIMIT_POST_ALERT"
    fi
    SCAN_ERROR=$(axonflow_result_text "$SCAN_RESULT" '.error // empty')
    axonflow_post_unchecked "${SCAN_ERROR:-the AxonFlow agent returned no decision}"
  fi
  # The redacted output is handed to Claude whole: its ASCII control
  # characters go, except newline and tab, and it is not cut.
  # Whether a redaction came is decided on the raw value: one made only of
  # control characters still raises the alert.
  REDACTED_RAW=$(printf '%s' "$SCAN_RESULT" | jq -r '.redacted_message // empty' 2>/dev/null)
  REDACTED=$(axonflow_clean_block "$REDACTED_RAW")
  POLICIES_FOUND=$(axonflow_result_text "$SCAN_RESULT" '.policies_evaluated // 0')
  # Explicit boolean read: jq's `//` treats false as absent, so the old
  # `.allowed // true` let an output deny through.
  ALLOWED=$(echo "$SCAN_RESULT" | jq -r 'if .allowed == false then "false" else "true" end' 2>/dev/null || echo "true")

  if [ -n "$REDACTED_RAW" ] && [ "$REDACTED_RAW" != "null" ]; then
    # PII detected in tool output. PostToolUse hooks cannot transform
    # the original output — we can only instruct Claude not to expose
    # the raw PII in its response to the user. The redaction reaches jq on
    # stdin: the agent chose its length.
    printf '%s' "$REDACTED" | jq -Rs \
      --arg policies "$POLICIES_FOUND" \
      '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: ("GOVERNANCE ALERT: PII/sensitive data detected in tool output (" + $policies + " policies evaluated). You MUST use this redacted version instead of the original: " + .)
        }
      }'
    exit 0
  elif [ "$ALLOWED" = "false" ]; then
    # Output blocked by policy (not just PII redaction)
    BLOCK_REASON=$(axonflow_result_text "$SCAN_RESULT" '.block_reason // "Policy violation in tool output"')
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

# No issues — exit silently
exit 0
