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
# The per-user identity the override suites present (X-User-Email, through the
# plugin's MCP headersHelper from AXONFLOW_USER_EMAIL). An override write is
# scoped to an individual user, and the platform refuses a session with no
# per-user identity for that reason before it answers anything else.
: "${AXONFLOW_E2E_USER_EMAIL:=claude-runtime-e2e@axonflow-test.invalid}"

# The session-override writes are retired from AxonFlow v11.0.0. Measured on a
# v11.0.0 community stack with AXONFLOW_TRUST_IDENTITY_HEADERS=true:
#   - MCP create_override / delete_override answer a tool error (isError: true)
#     whose text begins with OVERRIDE_FROZEN_PREFIX. create_override on a
#     session with no per-user identity is refused for its identity first.
#   - REST POST / DELETE /api/v1/overrides with a per-user identity answer
#     HTTP 409 {"error":{"code":"LEGACY_POLICY_WRITE_FROZEN","message":...}}.
#   - list_overrides and GET /api/v1/overrides are unchanged reads
#     ({"count":0,"overrides":[]} on a stack where none were ever created).
OVERRIDE_FROZEN_PREFIX="LEGACY_POLICY_WRITE_FROZEN: "
OVERRIDE_FROZEN_CODE="LEGACY_POLICY_WRITE_FROZEN"

# runtime_e2e_refuse_production <url> <what this suite writes there>
#
# Production Community SaaS (https://try.getaxonflow.com) is never a default
# target: a suite that registers a tenant, writes a policy or edits the
# database there changes live state (axonflow-enterprise#4249, comments
# 5684192928 and 5694502320). When <url>'s host is try.getaxonflow.com the
# suite SKIPs, naming what it would write, unless the operator set
# AXONFLOW_E2E_ALLOW_PRODUCTION=1 for this run. Any other host returns.
runtime_e2e_refuse_production() {
  local url="$1" writes="$2" host
  host=$(printf '%s' "$url" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#^[^@/]*@##; s#[:/?#].*$##' | tr '[:upper:]' '[:lower:]')
  case "$host" in
    try.getaxonflow.com|try.getaxonflow.com.) ;;
    *) return 0 ;;
  esac
  if [ "${AXONFLOW_E2E_ALLOW_PRODUCTION:-}" = "1" ]; then
    echo "WARNING: running against PRODUCTION Community SaaS at $url (AXONFLOW_E2E_ALLOW_PRODUCTION=1); this suite $writes"
    return 0
  fi
  echo "SKIP: $url is PRODUCTION Community SaaS, and this suite $writes."
  echo "      Point it at a stack you own, or set AXONFLOW_E2E_ALLOW_PRODUCTION=1 to run it there deliberately."
  exit 0
}

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
  # The plugin's MCP headersHelper sends AXONFLOW_USER_EMAIL as X-User-Email.
  export AXONFLOW_USER_EMAIL="${AXONFLOW_USER_EMAIL:-$AXONFLOW_E2E_USER_EMAIL}"

  local plugin_dir
  plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  local tmpdir
  tmpdir="$(mktemp -d -t axonflow-claude-e2e.XXXXXX)"

  # --setting-sources project, from an empty directory: the operator's own
  # user-level settings (their hooks, their other plugins) never run inside a
  # runtime proof of this plugin.
  ( cd "$tmpdir" && claude \
    --plugin-dir "$plugin_dir" \
    --setting-sources project \
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
  jq -r 'select(.type=="result") | .result' "$output_file" 2>/dev/null | grep "$needle" >/dev/null
}

# ---------------------------------------------------------------------------
# Real-credential helpers (self-hosted / Enterprise coverage).
#
# run_claude_with_tool() above ALWAYS injects demo-client:demo-secret and so
# can only exercise the happy auth path against a permissive (Community-SaaS-
# style) endpoint. It cannot cover (a) a self-hosted Enterprise agent with a
# REAL license, nor (b) the auth-MISSING misconfiguration that surfaces as the
# cryptic "axonflow failed / HTTP 404 Invalid OAuth error response". The
# helpers below exist precisely to close that gap — they never fabricate a
# credential.
# ---------------------------------------------------------------------------

# run_claude_plugin <auth-base64-or-empty> <prompt> <output-file>
#
# Drives the REAL claude binary with the plugin loaded via --plugin-dir and
# the EXACT credential passed: a non-empty value is exported as AXONFLOW_AUTH;
# an EMPTY value means AXONFLOW_AUTH is left UNSET, to reproduce the misconfig
# path. Unlike run_claude_with_tool this NEVER injects demo creds.
run_claude_plugin() {
  local auth="$1"
  local prompt="$2"
  local output_file="$3"

  local plugin_dir
  plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  local tmpdir
  tmpdir="$(mktemp -d -t axonflow-claude-rt.XXXXXX)"

  (
    cd "$tmpdir"
    export AXONFLOW_ENDPOINT
    if [ -n "$auth" ]; then
      export AXONFLOW_AUTH="$auth"
    else
      unset AXONFLOW_AUTH
    fi
    claude \
      --plugin-dir "$plugin_dir" \
      --setting-sources project \
      --print \
      --output-format stream-json \
      --verbose \
      --dangerously-skip-permissions \
      "$prompt" 2>&1
  ) > "$output_file" || true
  rm -rf "$tmpdir"
}

# mcp_axonflow_status <output-file> → prints connected|failed|pending|absent
# Reads Claude Code's own session-init event, i.e. the same source that backs
# the interactive `/mcp` list. "connected" here means the plugin's MCP server
# handshake (headersHelper → initialize) actually succeeded.
mcp_axonflow_status() {
  local f="$1" s
  s=$(jq -r 'select(.type=="system" and .subtype=="init") | .mcp_servers[]? | select(.name|startswith("plugin:axonflow")) | .status' \
    "$f" 2>/dev/null | head -1)
  [ -n "$s" ] && printf '%s' "$s" || printf 'absent'
}

# assert_no_raw_oauth_404 <output-file> → 0 if the stream does NOT contain the
# bare, unexplained OAuth-discovery 404 surfaced to the user. The whole point
# of the fix is that an auth/config problem becomes an actionable message
# (naming AXONFLOW_AUTH), not "Invalid OAuth error response ... 404 page not
# found".
assert_no_raw_oauth_404() {
  local f="$1"
  ! grep -qiE 'Invalid OAuth error response|Raw body: 404 page not found' "$f"
}

# tool_result_text <output-file> <tool-suffix>
#   The text of the tool_result Claude Code captured for the FIRST call to the
#   MCP tool ending in <tool-suffix> (matched by tool_use_id), or empty.
tool_result_text() {
  local f="$1" suffix="$2" id
  id=$(jq -r --arg s "$suffix" 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name | endswith($s))) | .id' "$f" 2>/dev/null | head -1)
  [ -n "$id" ] || return 0
  jq -r --arg id "$id" 'select(.type=="user") | .message.content[]? | select(.type=="tool_result" and .tool_use_id == $id) | .content | if type == "string" then . else (map(.text? // empty) | join("")) end' "$f" 2>/dev/null | head -c 4000
}

# tool_result_is_error <output-file> <tool-suffix>: "true" or "false".
tool_result_is_error() {
  local f="$1" suffix="$2" id
  id=$(jq -r --arg s "$suffix" 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name | endswith($s))) | .id' "$f" 2>/dev/null | head -1)
  [ -n "$id" ] || { echo false; return 0; }
  jq -r --arg id "$id" 'select(.type=="user") | .message.content[]? | select(.type=="tool_result" and .tool_use_id == $id) | (.is_error // false)' "$f" 2>/dev/null | head -1
}

# smoke_line <output-file>: the JSON after SMOKE_RESULT: in the agent's own
# final message (the stream's result event), or empty. The prompt is not in
# that event, so an agent that answered nothing yields nothing.
smoke_line() {
  jq -r 'select(.type=="result") | .result' "$1" 2>/dev/null | grep "SMOKE_RESULT:" | tail -1 | sed 's/.*SMOKE_RESULT: *//'
}

# mcp_tool_call <tool> <arguments JSON> [extra curl arguments ...]
#   Calls one MCP tool directly (not through Claude Code) with the suite's
#   credential and prints the raw JSON-RPC response: the channel-independent
#   check of what the platform answers.
mcp_tool_call() {
  local tool="$1" args="$2"
  shift 2
  jq -nc --arg t "$tool" --argjson a "$args" '{jsonrpc:"2.0",id:"1",method:"tools/call",params:{name:$t,arguments:$a}}' | \
    curl -s -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
      -H "Authorization: Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)" \
      "$@" --data-binary @- "$AXONFLOW_ENDPOINT/api/v1/mcp-server"
}

# mcp_override_count: the count list_overrides reports, or empty.
mcp_override_count() {
  mcp_tool_call list_overrides '{"include_revoked":true}' -H "X-User-Email: $AXONFLOW_E2E_USER_EMAIL" \
    | jq -r '.result.content[0].text // empty' 2>/dev/null | jq -r '.count // empty' 2>/dev/null
}

# assert_override_frozen_text <label> <is_error> <text>
#   0 when the answer is the retired-write tool error. A test that skips is not
#   a test (#3062): any other answer FAILS, with the text and the likely cause.
assert_override_frozen_text() {
  local label="$1" is_error="$2" text="$3"
  if [ "$is_error" = "true" ] && [ "${text#"$OVERRIDE_FROZEN_PREFIX"}" != "$text" ]; then
    echo "PASS: $label answered the retired write: $(printf '%s' "$text" | cut -c1-100)..."
    return 0
  fi
  echo "FAIL: $label did not answer a tool error beginning \"$OVERRIDE_FROZEN_PREFIX\" (is_error=$is_error)"
  echo "      Text: $(printf '%s' "$text" | cut -c1-600)"
  case "$text" in
    *"scoped to an individual user"*)
      echo "      The session carried no per-user identity, so the platform refused it for"
      echo "      identity first. The suite sends X-User-Email; the agent drops it unless"
      echo "      AXONFLOW_TRUST_IDENTITY_HEADERS=true is set on it. Only enable that when"
      echo "      every hop that can reach the agent asserts end-user identity from a"
      echo "      validated source."
      ;;
  esac
  return 1
}

# assert_mcp_override_frozen <label> <raw MCP response>
assert_mcp_override_frozen() {
  local is_error text
  is_error=$(printf '%s' "$2" | jq -r '.result.isError // false' 2>/dev/null)
  text=$(printf '%s' "$2" | jq -r '.result.content[0].text // ""' 2>/dev/null)
  assert_override_frozen_text "$1" "$is_error" "$text"
}

# assert_rest_override_frozen <label> <http status> <body>
assert_rest_override_frozen() {
  local label="$1" status="$2" body="${3:-}" code
  code=$(printf '%s' "$body" | jq -r '.error.code? // empty' 2>/dev/null)
  if [ "$status" = "409" ] && [ "$code" = "$OVERRIDE_FROZEN_CODE" ]; then
    echo "PASS: $label answered HTTP 409 $OVERRIDE_FROZEN_CODE"
    return 0
  fi
  echo "FAIL: $label answered HTTP $status (expected 409 $OVERRIDE_FROZEN_CODE)"
  [ -n "$body" ] && echo "      Body: $(printf '%s' "$body" | cut -c1-600)"
  if [ "$status" = "401" ]; then
    echo "      The override endpoints check a per-user identity before they answer the"
    echo "      retirement. The agent removed the X-User-Email this suite sent: set"
    echo "      AXONFLOW_TRUST_IDENTITY_HEADERS=true on the AGENT and restart it (only when"
    echo "      every hop that can reach it asserts end-user identity from a validated source)."
  fi
  return 1
}
