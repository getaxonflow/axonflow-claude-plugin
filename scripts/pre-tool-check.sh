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
# Exit 0 + JSON with only systemMessage = allow, with a notice the user sees
#
# Failure posture, one row per answer (the status classes are read by
# scripts/lib/failure-posture.sh, which post-tool-audit.sh reads too). Every
# block goes through axonflow_pre_deny, the structured deny above:
#   A policy decision: a JSON-RPC result on   -> enforced as the platform decided;
#   any status but 401 and 429                   a deny is a structured deny
#   HTTP 401, with or without a per-user      -> BLOCK: a rejected credential; the
#   token, or the auth-failure cooldown          cooldown blocks locally, naming the
#   a 401 stamps                                 seconds left and the stamp file
#   One JSON-RPC -32001 answer, on any HTTP   -> RUNS with a notice the user sees,
#   status but 429, with                         naming the switch (the documented
#   AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR set         break-glass; never a plain 401, a
#                                                429 or the cooldown)
#   HTTP 429, or a request-rate limit stamp   -> BLOCK: a request limit
#   A JSON-RPC error other than -32603 /      -> BLOCK: the agent refused the
#   -32700 (or with no numeric code); a 3xx;     request (endpoint, credential or
#   a 4xx other than 408 without a JSON-RPC      configuration); a 413 names the size
#   answer
#   A policy result that decides nothing (no -> BLOCK: an answer that decides
#   boolean "allowed", or flagged isError)       nothing never lets a tool call run
#   The request for this tool call could not  -> BLOCK: what governance would check
#   be built                                     was never sent
#   No usable answer: unreachable, timeout,   -> AXONFLOW_FAIL_MODE decides: unset, empty
#   408, 5xx, JSON-RPC -32603 / -32700, an       or "open" runs the tool UNGOVERNED with a
#   empty or unreadable body, jq or curl         notice the user sees; any other value
#   missing                                      blocks
#   scripts/lib/failure-posture.sh missing    -> BLOCK, naming the file

# The script's directory from builtins only: this runs before the dependency
# check below, on a PATH that may hold nothing but bash.
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

# Emit a structured PreToolUse deny and stop (the hook's one block: Claude Code
# shows the reason and does not run the tool).
axonflow_pre_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(_axonflow_json_string "$1")"
  exit 0
}

# Let the tool call run and tell the user why governance did not decide it.
# Claude Code does not show a hook's stderr on exit 0, so the notice goes in
# the hook JSON's systemMessage, which it shows to the user; no
# permissionDecision is set, so Claude Code's own permission flow is unchanged.
# The same line goes to stderr for logs.
axonflow_pre_notice() {
  echo "$1" >&2
  printf '{"systemMessage":%s}\n' "$(_axonflow_json_string "$1")"
  exit 0
}

# The failure-posture table this hook reads. Without it the hook cannot tell a
# decision from a refusal, so it blocks and says the install is incomplete.
# shellcheck source=./lib/failure-posture.sh
if ! . "${SCRIPT_DIR}/lib/failure-posture.sh" 2>/dev/null; then
  axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow plugin install is incomplete (scripts/lib/failure-posture.sh is missing or unreadable), so this tool call is blocked. Reinstall the plugin."
fi

# A governed check that got no usable answer. AXONFLOW_FAIL_MODE decides:
# unset, empty or "open" (any case) lets the tool call run UNGOVERNED and says
# so every time; any other value blocks it. It never applies to an answer that
# refused the call (a 401, a 429, a policy deny): those block.
axonflow_pre_ungoverned() {
  if ! axonflow_fail_mode_open; then
    axonflow_pre_deny "AxonFlow governance blocked: $1, and AXONFLOW_FAIL_MODE is \"${AXONFLOW_FAIL_MODE}\" (not \"open\"), so this tool call is blocked."
  fi
  axonflow_pre_notice "[AxonFlow] GOVERNANCE UNAVAILABLE: $1. This tool call runs UNGOVERNED. Set AXONFLOW_FAIL_MODE=closed to block tool calls when AxonFlow cannot answer."
}

# The hook cannot read the tool call or reach AxonFlow without these.
if ! command -v jq &>/dev/null; then
  axonflow_pre_ungoverned "the AxonFlow hook needs jq, which is not installed"
fi
if ! command -v curl &>/dev/null; then
  axonflow_pre_ungoverned "the AxonFlow hook needs curl, which is not installed"
fi

# Endpoint resolution per ADR-048: default to AxonFlow Community SaaS only when
# the user has not set explicit config. Any user-supplied AXONFLOW_ENDPOINT or
# AXONFLOW_AUTH is honoured untouched — no silent override.
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
# The configured per-request timeout (a positive integer; anything else is the
# default). The request itself gets no more than the hook's time budget leaves.
CONFIGURED_TIMEOUT_SECONDS="${AXONFLOW_TIMEOUT_SECONDS:-8}"
case "$CONFIGURED_TIMEOUT_SECONDS" in ''|*[!0-9]*|0) CONFIGURED_TIMEOUT_SECONDS=8 ;; esac
REQUEST_TIMEOUT_SECONDS="$CONFIGURED_TIMEOUT_SECONDS"
export AXONFLOW_MODE

# Mode-clarity canary on stderr (NEVER stdout — stdout is the hook protocol).
# CI's mode-clarity gate parses this line and asserts it matches the actual
# outbound destination. Users can never be misled about which AxonFlow they're
# talking to.
echo "[AxonFlow] Connected to AxonFlow at ${ENDPOINT} (mode=${AXONFLOW_MODE})" >&2

# Community-SaaS bootstrap: register with try.getaxonflow.com on first run and
# load the resulting Basic-auth credential into AXONFLOW_AUTH. No-op when the
# user has set explicit config (AXONFLOW_MODE != community-saas).
# The registration gets at most 5 seconds, and only what the budget leaves
# after holding 4 back for the policy check itself.
_AXONFLOW_REGISTER_MAX_TIME=$(axonflow_budget_timeout 5 4)
# Only this run's bootstrap may define its cleanup: nothing of that name from
# the environment (an exported shell function) is ever called.
unset _AXONFLOW_BOOTSTRAP_TRAP
unset -f _axonflow_bootstrap_cleanup_on_exit 2>/dev/null
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
# axonflow-enterprise#1958) and the shared throttle-until stamp. Provides
# axonflow_governed_stamp + axonflow_handle_envelope_response. See
# scripts/upgrade-prompt.sh.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/upgrade-prompt.sh"

# Build auth header array safely (avoids word-splitting)
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

# #2935: when a per-user token was sent, name it as a likely cause of a
# rejected credential — the platform fails closed on a presented-but-invalid
# X-User-Token (expired, revoked, wrong org), and the generic "fix
# AXONFLOW_AUTH" guidance would send the operator down the wrong path. Names
# the token's config surfaces, NEVER its value.
USER_TOKEN_HINT=""
if [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then
  USER_TOKEN_HINT=" A per-user token is configured (AXONFLOW_USER_TOKEN / user-token.json) and was sent as X-User-Token — if it is expired, revoked, or minted for a different org, the platform rejects the request; ask your admin to rotate it, or remove it to fall back to shared-credential attribution."
fi
AUTH_HINT="Fix AXONFLOW_AUTH (or refresh your credentials) to restore tool access.${USER_TOKEN_HINT}"

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
"${SCRIPT_DIR}/telemetry-ping.sh" </dev/null >/dev/null &
# Plugin/platform version compatibility check — fire-and-forget, runs once
# per install, warns to stderr if the plugin is below the platform's
# min_plugin_version (axonflow-enterprise#1764). Same fire-and-forget shape
# as telemetry-ping; never blocks the hook hot path.
"${SCRIPT_DIR}/version-check.sh" </dev/null >/dev/null &

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
    # Claude Code sends a NotebookEdit's code as new_source; the older names
    # are kept for other shapes.
    STATEMENT=$(echo "$TOOL_INPUT" | jq -r '.new_source // .cell_content // .content // empty')
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

# An input with nothing to check (an MCP call with no arguments, an empty
# command, a NotebookEdit delete, which sends no new_source) is still a governed
# call: it is checked as the tool's name plus the input's plain fields (the
# notebook path, cell id, edit mode), never skipped. A shell command that is
# literally "null" or "{}" is that command, and is checked as it is.
NOTHING_TO_CHECK=""
case "$TOOL_NAME" in
  Bash|Shell)
    [ -z "$STATEMENT" ] && NOTHING_TO_CHECK=1
    ;;
  *)
    if [ -z "$STATEMENT" ] || [ "$STATEMENT" = "null" ] || [ "$STATEMENT" = "{}" ]; then
      NOTHING_TO_CHECK=1
    fi
    ;;
esac
if [ -n "$NOTHING_TO_CHECK" ]; then
  STATEMENT=$(printf '%s' "$TOOL_INPUT" | jq -c --arg t "$TOOL_NAME" \
    '{tool: $t} + (if type == "object" then with_entries(select(.value | type == "string" or type == "number" or type == "boolean")) else {} end)' 2>/dev/null)
  if [ -z "$STATEMENT" ]; then
    STATEMENT="{\"tool\":$(_axonflow_json_string "$TOOL_NAME")}"
  fi
fi

# Back-off: a recent governed call stamped the shared throttle-until file, and
# the hook answers locally instead of re-sending a request the platform
# refused. Two stamps gate (scripts/upgrade-prompt.sh, the stamp rules):
#   - the 401 cooldown (auth_failure, axonflow-enterprise#2275): the credential
#     was rejected, and a rejected credential never lets a tool call run. The
#     cooldown only spares the platform the retry storm;
#   - a request-rate limit (daily_quota, per_minute), for at most 300 seconds
#     after it was written: over the cap is deny, not governance off (ruled
#     2026-09-14).
# Any other stamp (a feature or object-count limit, or one past the cap) gates
# nothing and is left on disk for the plugin that wrote it.
GOVERNED_STAMP=$(axonflow_governed_stamp)
case "$GOVERNED_STAMP" in
  auth_failure)
    axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent rejected authentication (HTTP 401) and an auth-failure cooldown is active, so this tool call is blocked. $(axonflow_auth_cooldown_note) ${AUTH_HINT}"
    ;;
  limit)
    axonflow_pre_deny "$AXONFLOW_LIMIT_DENY_REASON"
    ;;
esac

# Call AxonFlow check_policy via MCP server.
#
# V1 Plugin Pro: capture HTTP status + headers + body separately so the
# envelope handler can detect 429 / 403 and stamp the throttle deadline
# before we fall through to the JSON-RPC parser.
PRECHECK_REQUEST=$(mktemp)
PRECHECK_BODY=$(mktemp)
PRECHECK_HEADERS=$(mktemp)
trap 'rm -f "$PRECHECK_REQUEST" "$PRECHECK_BODY" "$PRECHECK_HEADERS"; axonflow_bootstrap_cleanup' EXIT

# The statement reaches jq on stdin and the body reaches curl as a file, never
# as a command-line argument: an argument has a size limit (about 128 KiB on
# Linux), and the model chooses the command's length. If the request cannot be
# built, what governance would check was never sent, and the call is blocked.
if ! printf '%s' "$STATEMENT" | jq -Rsc --arg ct "$CONNECTOR_TYPE" \
    '{
      jsonrpc: "2.0",
      id: "hook-pre",
      method: "tools/call",
      params: {
        name: "check_policy",
        arguments: {
          connector_type: $ct,
          statement: .,
          operation: "execute"
        }
      }
    }' > "$PRECHECK_REQUEST" 2>/dev/null || [ ! -s "$PRECHECK_REQUEST" ]; then
  axonflow_pre_deny "AxonFlow governance blocked: the policy check request for this tool call could not be built, so the call was never checked and is blocked."
fi

# Community SaaS with no credential after the bootstrap (the registration did
# not complete: unreachable, refused, rate limited, or out of time): there is
# nothing to authenticate the check with, so it is no usable answer. No request
# is sent (it could only be refused as a 401, which would stamp a cooldown and
# name a variable the user never set), and no stamp is written.
if [ "${AXONFLOW_MODE:-}" = "community-saas" ] && [ -z "$AUTH" ]; then
  axonflow_pre_ungoverned "the AxonFlow Community SaaS registration has not completed, so there is no credential to ask the AxonFlow agent at ${ENDPOINT} with"
fi

REQUEST_TIMEOUT_SECONDS=$(axonflow_budget_timeout "$CONFIGURED_TIMEOUT_SECONDS" 1)
if [ "$REQUEST_TIMEOUT_SECONDS" -lt 1 ]; then
  axonflow_pre_ungoverned "the hook's ${_AXONFLOW_HOOK_BUDGET_SECONDS}-second time budget ran out before the AxonFlow agent at ${ENDPOINT} could be asked"
fi
HTTP_CODE=$(curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" \
  -D "$PRECHECK_HEADERS" -o "$PRECHECK_BODY" -w '%{http_code}' \
  -X POST "${ENDPOINT}/api/v1/mcp-server" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  "${AUTH_HEADER[@]}" \
  --data-binary @"$PRECHECK_REQUEST" 2>/dev/null)
CURL_EXIT=$?

# Any curl-level failure (exit != 0) means no answer arrived — timeout, DNS
# failure, connection refused, TCP reset.
if [ "$CURL_EXIT" -ne 0 ]; then
  axonflow_pre_ungoverned "the AxonFlow agent at ${ENDPOINT} could not be reached (curl exit ${CURL_EXIT})"
fi

# Detect the V1 Plugin Pro envelope on 429 / 403. When present, the helper
# stamps throttle-until + emits the upgrade prompt to stderr, and the tool
# call is DENIED: over a hosted Free-tier limit is deny with the visible
# upgrade prompt, not governance off (ruled 2026-09-14; reversible here).
if axonflow_handle_envelope_response "$HTTP_CODE" "$PRECHECK_BODY" "$PRECHECK_HEADERS"; then
  axonflow_pre_deny "$(axonflow_limit_deny_reason)"
fi

RESPONSE=$(cat "$PRECHECK_BODY")

# The platform's own words for a refusal (a JSON-RPC error message, a coded
# error envelope's message, or a plain {"error": "..."} body), with control
# characters dropped and capped, quoted as the platform's: any proxy in the way
# can write this text, and it reaches Claude Code and the model. Empty for a
# body that is not JSON (an HTML error page).
PLATFORM_TEXT=$(axonflow_platform_text "$RESPONSE")
SAID="${PLATFORM_TEXT:+; AxonFlow said: \"$PLATFORM_TEXT\"}"

# The -32001 answer (a rejected credential, or on a community AxonFlow v11.0.0
# agent a client id the organization has not admitted) is named in full: which
# variables to set, and the break-glass.
AUTH_32001_DENY="AxonFlow governance is fail-closed: the agent at ${ENDPOINT} rejected the policy check with an authentication error (\"${PLATFORM_TEXT:-no message}\", code -32001), so this tool call is blocked. On a self-hosted / Enterprise (in-VPC) agent this means credentials are required. Fix: set AXONFLOW_ENDPOINT to your agent URL and AXONFLOW_AUTH to base64(org_id:license_key) — e.g. export AXONFLOW_AUTH=\$(printf %s \"<org_id>:<license_key>\" | base64) — then restart Claude Code.${USER_TOKEN_HINT} Docs: https://docs.getaxonflow.com/docs/integration/claude-code#self-hosted--enterprise-authentication . Break-glass to keep working ungoverned while you fix it: export AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1 (not recommended)."

# AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR, the documented break-glass: set to 1 or
# true, an answer carrying JSON-RPC -32001 lets the tool call run UNGOVERNED,
# with a notice the user sees every time. It covers only -32001: a plain 401
# and the auth-failure cooldown still block. It does not stamp the cooldown,
# which would block the next call.
axonflow_break_glass_set() {
  [ "${AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR:-}" = "1" ] || [ "${AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR:-}" = "true" ]
}
axonflow_break_glass_notice() {
  axonflow_pre_notice "[AxonFlow] WARNING: auth error from ${ENDPOINT} (code -32001; AxonFlow said: \"${PLATFORM_TEXT:-no message}\"); AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR is set, so this tool call is ALLOWED WITHOUT GOVERNANCE. Set AXONFLOW_AUTH=base64(org_id:license_key) and unset this break-glass to restore enforcement."
}

# HTTP 401. A 401 carrying -32001 with the break-glass set runs with its notice.
# Every other 401 stamps the cooldown (the helper; 300 seconds by default) so a
# tight retry loop can't fire 716 × 401 in 24h (axonflow-enterprise#2275), and
# the tool call is BLOCKED: a rejected credential never lets a tool call run,
# with or without a per-user token. The cooldown then blocks locally, with no
# network round-trip.
if [ "$HTTP_CODE" = "401" ]; then
  if [ "$(axonflow_jsonrpc_error_code "$RESPONSE")" = "-32001" ] && axonflow_break_glass_set; then
    axonflow_break_glass_notice
  fi
  axonflow_handle_auth_failure "$HTTP_CODE" "$PRECHECK_BODY" "$PRECHECK_HEADERS"
  if [ "$(axonflow_jsonrpc_error_code "$RESPONSE")" = "-32001" ]; then
    axonflow_pre_deny "${AUTH_32001_DENY} $(axonflow_auth_cooldown_note)"
  fi
  axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent at ${ENDPOINT} rejected authentication (HTTP 401${SAID}), so this tool call is blocked. $(axonflow_auth_cooldown_note) ${AUTH_HINT}"
fi

# The HTTP status of an answer the lines above did not settle, read by the
# shared table (scripts/lib/failure-posture.sh). A body that is a JSON-RPC
# answer (a non-null result, or an error object) is the platform's answer on
# any status but 429, and goes on to the decision path below: a 403 carrying a
# policy deny stays a policy deny. Only a body WITHOUT one is judged by status.
IS_JSONRPC=$(axonflow_is_jsonrpc_answer "$RESPONSE")
case "$(axonflow_status_class "$HTTP_CODE" "$IS_JSONRPC")" in
  answer) ;;
  limit)
    axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent answered HTTP 429 (a request limit was reached${SAID}), so this tool call is blocked until the limit resets."
    ;;
  too_large)
    axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent at ${ENDPOINT} refused the policy check as too large (HTTP 413${SAID}), so this tool call is blocked. The agent, or a proxy in front of it, limits the request size."
    ;;
  refused)
    axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent at ${ENDPOINT} refused the request (HTTP ${HTTP_CODE}${SAID}), so this tool call is blocked. Check AXONFLOW_ENDPOINT (a redirect means the URL needs changing) and AXONFLOW_AUTH."
    ;;
  *)
    axonflow_pre_ungoverned "the AxonFlow agent answered HTTP ${HTTP_CODE}${SAID}"
    ;;
esac

# An empty body from an otherwise-successful call carries no decision (a 204,
# or a proxy in the way).
if [ -z "$RESPONSE" ]; then
  axonflow_pre_ungoverned "the AxonFlow agent answered HTTP ${HTTP_CODE} with an empty body"
fi

# A body that is not exactly one JSON document is no usable answer. Two
# documents (a result and an error, in either order) would each be read by a
# different line below, and the allow could win.
if ! axonflow_one_json_document "$RESPONSE"; then
  axonflow_pre_ungoverned "the AxonFlow agent's answer (HTTP ${HTTP_CODE}) was not one JSON document"
fi

# Check for JSON-RPC error responses and apply the fail-open / fail-closed
# policy from issue #1545 Direction 3:
#
#   Auth errors (-32001):       BLOCK — operator must fix AXONFLOW_AUTH
#                               (runs, with its notice, under the break-glass)
#   Method not found (-32601):  BLOCK — plugin version mismatch with agent
#   Invalid params (-32602):    BLOCK — plugin bug, operator should upgrade
#   Parse errors (-32700):      no usable answer (AXONFLOW_FAIL_MODE)
#   Internal errors (-32603):   no usable answer (AXONFLOW_FAIL_MODE)
#   Everything else:            BLOCK — unknown code, fail closed (2026-09-14)
#   An error with no numeric code, or no message, is still an error: it blocks.
JSONRPC_CODE=$(axonflow_jsonrpc_error_code "$RESPONSE")
if [ -n "$JSONRPC_CODE" ]; then
  JSONRPC_ERROR="${PLATFORM_TEXT:-no message}"
  case "$JSONRPC_CODE" in
    -32001)
      if axonflow_break_glass_set; then
        axonflow_break_glass_notice
      fi
      axonflow_pre_deny "$AUTH_32001_DENY"
      ;;
    -32601|-32602)
      # Method not found / invalid params — plugin/agent version mismatch or
      # a plugin bug. Fail closed; the operator should upgrade.
      axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent refused the policy check (code ${JSONRPC_CODE}; AxonFlow said: \"${JSONRPC_ERROR}\"). This usually means the plugin and the AxonFlow agent are on incompatible versions — upgrade the plugin or the agent so the MCP method set matches, then restart Claude Code."
      ;;
    -32603|-32700)
      axonflow_pre_ungoverned "the AxonFlow agent answered a server error (code ${JSONRPC_CODE}; AxonFlow said: \"${JSONRPC_ERROR}\")"
      ;;
    *)
      # An unknown code is not a decision: fail closed (ruled 2026-09-14).
      axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent answered an unexpected error (code ${JSONRPC_CODE}; AxonFlow said: \"${JSONRPC_ERROR}\"), so this tool call is blocked."
      ;;
  esac
fi

# Parse the MCP response to get the tool result
TOOL_RESULT=$(echo "$RESPONSE" | jq -r '.result.content[0].text // empty' 2>/dev/null || echo "")
if [ -z "$TOOL_RESULT" ]; then
  # A JSON-RPC result with no tool result carries no decision: fail closed.
  # Anything else (no result object at all) is not a usable answer.
  if echo "$RESPONSE" | jq -e 'has("result")' >/dev/null 2>&1; then
    axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent returned a policy result without a decision, so this tool call is blocked."
  fi
  axonflow_pre_ungoverned "the AxonFlow agent's answer (HTTP ${HTTP_CODE}) was not a policy result"
fi

# A result flagged isError, or one without a boolean `allowed`, is not a
# decision: fail closed (ruled 2026-09-14). The Community SaaS Free-tier cap
# answers exactly this way, with its upgrade envelope as the result text;
# the envelope goes through the handler so the prompt and throttle still apply.
RESULT_IS_ERROR=$(echo "$RESPONSE" | jq -r 'if .result.isError == true then "true" else "false" end' 2>/dev/null || echo "false")
HAS_DECISION=$(echo "$TOOL_RESULT" | jq -r 'if (.allowed | type) == "boolean" then "true" else "false" end' 2>/dev/null || echo "false")
if [ "$RESULT_IS_ERROR" = "true" ] || [ "$HAS_DECISION" != "true" ]; then
  if axonflow_handle_envelope_text "$TOOL_RESULT"; then
    axonflow_pre_deny "$(axonflow_limit_deny_reason)"
  fi
  RESULT_ERROR=$(axonflow_result_text "$TOOL_RESULT" '.error // empty')
  axonflow_pre_deny "AxonFlow governance blocked: ${RESULT_ERROR:-the AxonFlow agent returned a policy result without a decision}, so this tool call is blocked."
fi

# Note: jq's // operator treats false as falsy, so .allowed // true returns
# true even when .allowed is false. Use explicit if/else instead.
ALLOWED=$(echo "$TOOL_RESULT" | jq -r 'if .allowed == false then "false" else "true" end' 2>/dev/null || echo "true")
BLOCK_REASON=$(axonflow_result_text "$TOOL_RESULT" '.block_reason // empty')
POLICIES_EVALUATED=$(axonflow_result_text "$TOOL_RESULT" '.policies_evaluated // 0')

# Plugin Batch 1 (ADR-042 + ADR-043): richer block context surfaced when
# the platform is v7.1.0+. All fields are optional; absent on older platforms.
# Every field printed below came from the network: its control characters go.
DECISION_ID=$(axonflow_result_text "$TOOL_RESULT" '.decision_id // empty')
RISK_LEVEL=$(axonflow_result_text "$TOOL_RESULT" '.risk_level // empty')
OVERRIDE_AVAILABLE=$(echo "$TOOL_RESULT" | jq -r '.override_available // false' 2>/dev/null || echo "false")
OVERRIDE_EXISTING_ID=$(axonflow_result_text "$TOOL_RESULT" '.override_existing_id // empty')

# Issue #2746: requires_redaction path. When check_policy returns
# requires_redaction:true (PII under a redact-action policy), deny the tool
# call before it executes and give Claude the masked content to retry with.
# This prevents the first Write from landing raw PII on disk. Whether a
# redaction came is decided on the raw value; the masked content handed to
# Claude loses its ASCII control characters except newline and tab.
REQUIRES_REDACTION=$(echo "$TOOL_RESULT" | jq -r 'if .requires_redaction == true then "true" else "false" end' 2>/dev/null || echo "false")
REDACTED_STATEMENT_RAW=$(printf '%s' "$TOOL_RESULT" | jq -r '.redacted_statement // empty' 2>/dev/null)

# A result that requires a redaction but carries no redacted statement decides
# nothing: there is nothing to retry with, and allowing the original would
# ignore the platform's "redact".
if [ "$REQUIRES_REDACTION" = "true" ] && [ -z "$REDACTED_STATEMENT_RAW" ]; then
  axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent required a redaction but returned no redacted content, so this tool call is blocked."
fi

if [ "$REQUIRES_REDACTION" = "true" ] && [ -n "$REDACTED_STATEMENT_RAW" ]; then
  REDACTED_STATEMENT=$(axonflow_clean_block "$REDACTED_STATEMENT_RAW")
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
  jq -nc \
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
            caller_name: "claude_code",
            tool_type: "claude_code",
            input: {statement: "[redacted]"},
            output: {policy_decision: "redacted", policies_evaluated: $policies},
            success: false,
            error_message: "PII detected — retry with redacted content"
          }
        }
      }' 2>/dev/null | curl -s --max-time "$REQUEST_TIMEOUT_SECONDS" -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
    --data-binary @- > /dev/null 2>&1 &

  # The masked content reaches jq on stdin: the agent chose its length.
  printf '%s' "$REDACTED_CONTENT" | jq -Rs \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "AxonFlow detected PII in the tool input. Please retry using the redacted version provided in additionalContext.",
        additionalContext: ("AxonFlow redacted PII from the input. Use this version instead:\n\n" + .)
      }
    }'
  exit 0
fi

if [ "$ALLOWED" = "false" ]; then
  # Record the blocked attempt in the audit trail (fire-and-forget).
  # This ensures blocked events appear in audit search and compliance reports.
  # The statement reaches jq on stdin, never as a command-line argument.
  printf '%s' "$STATEMENT" | jq -Rsc \
      --arg tn "$TOOL_NAME" \
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
            caller_name: "claude_code",
            tool_type: "claude_code",
            input: {statement: .},
            output: {policy_decision: "blocked", block_reason: $reason, policies_evaluated: $policies},
            success: false,
            error_message: ("Blocked by policy: " + $reason)
          }
        }
      }' 2>/dev/null | curl -s --max-time "$REQUEST_TIMEOUT_SECONDS" -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
    --data-binary @- > /dev/null 2>&1 &

  # Return deny decision to Claude Code. Plugin Batch 1: surface richer
  # context (decision_id, risk_level, override availability) when the
  # platform provides it. The override hint renders only on platforms before
  # v11.0.0: from v11 the platform never reports an override as available
  # (overrides are retired).
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

  axonflow_pre_deny "AxonFlow policy violation: ${BLOCK_REASON} (${POLICIES_EVALUATED} policies evaluated)${CONTEXT_SUFFIX}"
fi

# Allowed — no output needed
exit 0
# CI re-trigger: 1777491394
