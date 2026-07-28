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

  local plugin_dir
  plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  local tmpdir
  tmpdir="$(mktemp -d -t axonflow-claude-e2e.XXXXXX)"

  ( cd "$tmpdir" && claude \
    --plugin-dir "$plugin_dir" \
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
  jq -r 'select(.type=="result") | .result' "$output_file" 2>/dev/null | grep -q "$needle"
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

# require_override_preflight <http_status> <body> [extra_hint]
#
# Classifies the result of the override-create pre-flight the override
# lifecycle tests use to seed state. Every one of them previously printed
# `SKIP: pre-flight create_override returned HTTP $STATUS` and exited 0 on ANY
# non-201 — so they passed-by-skipping in exactly the default configuration
# every user runs (#3062): the agent strips X-User-Email unless
# AXONFLOW_TRUST_IDENTITY_HEADERS=true, so create_override 401s and the suite
# reported green while two of the eleven advertised tools were dead.
#
# A test that skips is not a test. The ONLY legitimate exit-0 here is
# environment unavailability, which the harness checks before this point. A
# reachable stack that refuses to create an override is a FAILURE, and this
# prints the remediation instead of swallowing it.
require_override_preflight() {
  local status="$1"
  local body="$2"
  local extra_hint="${3:-}"

  if [ "$status" = "201" ]; then
    return 0
  fi

  echo "FAIL: pre-flight create_override returned HTTP $status (expected 201)"
  echo "      Body: $body"
  [ -n "$extra_hint" ] && echo "      $extra_hint"
  echo ""

  case "$status" in
    401)
      echo "      The override endpoints require a per-user identity. This deployment"
      echo "      is not configured to trust client-asserted identity headers, so the"
      echo "      AxonFlow Agent removed the X-User-Email this test sent."
      echo ""
      echo "      Set the posture this test requires, then re-run:"
      echo "        AXONFLOW_TRUST_IDENTITY_HEADERS=true   # on the AGENT, then restart it"
      echo ""
      echo "      Only enable it when every hop that can reach the agent asserts"
      echo "      end-user identity from a validated source — see"
      echo "      docs/security/identity-header-trust.md in axonflow-enterprise."
      ;;
    403)
      echo "      The stack rejected the override on policy grounds. Check the seed"
      echo "      policy is overridable (not critical-risk, allow_override=true) —"
      echo "      migration 076 sets severity=critical => allow_override=FALSE."
      ;;
    404)
      echo "      The seed policy was not found for this tenant. Confirm the stack's"
      echo "      migrations ran and that X-Tenant-ID matches the seeded tenant."
      ;;
  esac

  return 1
}
