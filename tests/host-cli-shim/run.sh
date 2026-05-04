#!/usr/bin/env bash
# Host-CLI shim test — simulates the Claude Code host's plugin lifecycle.
#
# The existing tests/test-hooks.sh and tests/install-smoke/run.sh exercise
# the hook scripts directly (bash hook.sh < event.json) but never read the
# plugin's manifest the way the Claude Code binary would. This shim is a
# higher-fidelity smoke test: it stages the plugin to a tmp dir as
# `claude plugin install` would, parses the manifests (.claude-plugin/
# plugin.json, hooks/hooks.json, .mcp.json), and drives the discovered
# hook scripts in the order the host would, with the same JSON-on-stdin
# event contract Claude Code uses (PreToolUse → tool → PostToolUse).
#
# What it asserts (across three tier scenarios — Free, Pro/env, Pro/file):
#
#   1. PreToolUse hook fires for a Bash tool call and the captured agent
#      request includes (or omits) X-License-Token according to tier.
#   2. PostToolUse hook fires after the tool "succeeds" and the captured
#      agent request includes (or omits) X-License-Token according to tier.
#   3. The headersHelper from .mcp.json — invoked once per host MCP-session
#      bootstrap — emits a header set that includes X-License-Token when a
#      Pro license is present. (This catches the regression in claude#56:
#      the inline-bash headersHelper drops X-License-Token, so MCP traffic
#      gets Free-tier treatment for Pro users. Today this assertion is
#      EXPECTED to fail on Pro tiers — the test marks it as XFAIL until
#      claude#56 lands. See `expect_mcp_token_forwarded` below.)
#   4. Free-tier scenario: NO captured request carries X-License-Token.
#   5. PreToolUse deny path: when the policy stub answers `allowed=false`,
#      the hook output JSON includes `permissionDecision=deny` AND a follow-
#      up audit_tool_call request is captured.
#
# Stdlib-only: bash + curl + jq + python3 stub. No live AxonFlow stack.
#
# Usage:
#   ./tests/host-cli-shim/run.sh                # all scenarios
#   PASS_PRINT=1 ./tests/host-cli-shim/run.sh   # print each pass

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not on PATH"
  exit 0
fi

STAGE_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t host-cli-shim)
LOG_DIR="$STAGE_DIR/.logs"
HOME_DIR="$STAGE_DIR/home"
CAPTURE_FILE="$STAGE_DIR/capture.jsonl"
mkdir -p "$LOG_DIR" "$HOME_DIR/.config/axonflow"
chmod 0700 "$HOME_DIR/.config/axonflow"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { [ -n "${PASS_PRINT:-}" ] && echo "  PASS: $1"; PASS=$((PASS+1)); }
xfail() { echo "  XFAIL (expected, tracked): $1"; }

cleanup() {
  if [ -n "${STUB_PID:-}" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Stage the plugin like `claude plugin install` would
# ---------------------------------------------------------------------------
echo "stage plugin to $STAGE_DIR/plugin"
PLUGIN_STAGE="$STAGE_DIR/plugin"
mkdir -p "$PLUGIN_STAGE/.claude-plugin" "$PLUGIN_STAGE/hooks" \
         "$PLUGIN_STAGE/scripts" "$PLUGIN_STAGE/commands" \
         "$PLUGIN_STAGE/skills"

cp -p "$PLUGIN_DIR/.claude-plugin/plugin.json" "$PLUGIN_STAGE/.claude-plugin/" \
  || { fail "missing .claude-plugin/plugin.json"; exit 1; }
cp -p "$PLUGIN_DIR/.mcp.json" "$PLUGIN_STAGE/" \
  || { fail "missing .mcp.json"; exit 1; }
cp -p "$PLUGIN_DIR/hooks/hooks.json" "$PLUGIN_STAGE/hooks/" \
  || { fail "missing hooks/hooks.json"; exit 1; }

# Stage every script (the manifest references them by name).
cp -p "$PLUGIN_DIR/scripts"/*.sh "$PLUGIN_STAGE/scripts/"
chmod +x "$PLUGIN_STAGE/scripts/"*.sh

pass "plugin payload staged"

# ---------------------------------------------------------------------------
# 2. Parse manifests like the host would
# ---------------------------------------------------------------------------
PLUGIN_NAME=$(jq -r '.name' "$PLUGIN_STAGE/.claude-plugin/plugin.json")
[ "$PLUGIN_NAME" = "axonflow" ] && pass "plugin name=axonflow" \
  || fail "plugin name mismatch: got '$PLUGIN_NAME'"

PRE_HOOK_CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$PLUGIN_STAGE/hooks/hooks.json")
POST_HOOK_CMD=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$PLUGIN_STAGE/hooks/hooks.json")

# Resolve ${CLAUDE_PLUGIN_ROOT} the same way the host does.
PRE_HOOK_RESOLVED="${PRE_HOOK_CMD//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_STAGE}"
POST_HOOK_RESOLVED="${POST_HOOK_CMD//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_STAGE}"

[ -x "$PRE_HOOK_RESOLVED" ] && pass "PreToolUse hook resolves: $(basename "$PRE_HOOK_RESOLVED")" \
  || fail "PreToolUse hook not executable at '$PRE_HOOK_RESOLVED'"
[ -x "$POST_HOOK_RESOLVED" ] && pass "PostToolUse hook resolves: $(basename "$POST_HOOK_RESOLVED")" \
  || fail "PostToolUse hook not executable at '$POST_HOOK_RESOLVED'"

HEADERS_HELPER=$(jq -r '.mcpServers.axonflow.headersHelper // empty' "$PLUGIN_STAGE/.mcp.json")
[ -n "$HEADERS_HELPER" ] && pass "headersHelper present in .mcp.json" \
  || fail "headersHelper missing from .mcp.json"

# ---------------------------------------------------------------------------
# 3. Start the capture stub
# ---------------------------------------------------------------------------
STUB_LOG="$LOG_DIR/stub.log"
CAPTURE_FILE="$CAPTURE_FILE" \
  python3 "$SCRIPT_DIR/capture-stub.py" 0 >"$STUB_LOG" 2>&1 &
STUB_PID=$!

# Spin until the stub prints its port marker.
PORT=""
for _ in $(seq 1 50); do
  if grep -q '^PORT=' "$STUB_LOG" 2>/dev/null; then
    PORT=$(grep -oE 'PORT=[0-9]+' "$STUB_LOG" | head -1 | cut -d= -f2)
    break
  fi
  sleep 0.1
done
if [ -z "$PORT" ]; then
  fail "capture-stub failed to start"
  cat "$STUB_LOG"
  exit 1
fi
pass "capture-stub listening on 127.0.0.1:$PORT"
ENDPOINT="http://127.0.0.1:$PORT"

# Verify /health is reachable before driving hooks.
if curl -sSf -o /dev/null --max-time 2 "$ENDPOINT/health"; then
  pass "stub /health responds"
else
  fail "stub /health unreachable"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Helpers that drive the lifecycle in one tier scenario
# ---------------------------------------------------------------------------
# Each scenario truncates the capture file, fires PreToolUse + PostToolUse
# with the canonical Claude Code event shape, and inspects what the stub
# captured.

reset_captures() { : > "$CAPTURE_FILE"; }

# JSON-on-stdin event shape Claude Code sends to PreToolUse / PostToolUse.
# tool_name + tool_input for PreToolUse; same plus tool_response for Post.
fire_pretooluse() {
  local statement="${1:-echo benign}"
  local out
  out=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$statement\"}}" | \
    HOME="$HOME_DIR" \
    AXONFLOW_ENDPOINT="$ENDPOINT" \
    AXONFLOW_TELEMETRY=off \
    AXONFLOW_LICENSE_TOKEN="${LICENSE_TOKEN:-}" \
    AXONFLOW_AUTH="${AXONFLOW_AUTH:-}" \
    "$PRE_HOOK_RESOLVED" 2>/dev/null)
  echo "$out"
}

fire_posttooluse() {
  local statement="${1:-echo benign}"
  local stdout="${2:-ok}"
  local out
  out=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$statement\"},\"tool_response\":{\"stdout\":\"$stdout\",\"exitCode\":0}}" | \
    HOME="$HOME_DIR" \
    AXONFLOW_ENDPOINT="$ENDPOINT" \
    AXONFLOW_TELEMETRY=off \
    AXONFLOW_LICENSE_TOKEN="${LICENSE_TOKEN:-}" \
    AXONFLOW_AUTH="${AXONFLOW_AUTH:-}" \
    "$POST_HOOK_RESOLVED" 2>/dev/null)
  echo "$out"
}

# Returns the count of captured requests carrying X-License-Token.
captured_with_license_token() {
  jq -s 'map(select(.headers["x-license-token"] != null)) | length' "$CAPTURE_FILE"
}

# Returns the count of captured requests for a given JSON-RPC tool name.
captured_with_tool() {
  local tool="$1"
  jq -s --arg t "$tool" 'map(select(.tool_name == $t)) | length' "$CAPTURE_FILE"
}

# Invokes headersHelper as Claude Code would and prints the resolved JSON.
invoke_headers_helper() {
  CLAUDE_PLUGIN_ROOT="$PLUGIN_STAGE" \
  HOME="$HOME_DIR" \
  AXONFLOW_ENDPOINT="$ENDPOINT" \
  AXONFLOW_LICENSE_TOKEN="${LICENSE_TOKEN:-}" \
  AXONFLOW_AUTH="${AXONFLOW_AUTH:-}" \
  bash -c "$HEADERS_HELPER" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 5. Scenario A — Free tier (no token)
# ---------------------------------------------------------------------------
echo "--- scenario: Free tier ---"
LICENSE_TOKEN=""
reset_captures
PRE_OUT=$(fire_pretooluse "echo benign")
fire_posttooluse "echo benign" "ok" >/dev/null

PRE_REQ_COUNT=$(captured_with_tool "check_policy")
[ "$PRE_REQ_COUNT" -ge 1 ] && pass "Free: PreToolUse fired check_policy" \
  || fail "Free: PreToolUse did not call check_policy (got $PRE_REQ_COUNT)"

POST_REQ_COUNT=$(captured_with_tool "audit_tool_call")
[ "$POST_REQ_COUNT" -ge 1 ] && pass "Free: PostToolUse fired audit_tool_call" \
  || fail "Free: PostToolUse did not call audit_tool_call (got $POST_REQ_COUNT)"

LIC_COUNT=$(captured_with_license_token)
[ "$LIC_COUNT" -eq 0 ] && pass "Free: NO captured requests carry X-License-Token" \
  || fail "Free: $LIC_COUNT request(s) carried X-License-Token (should be 0)"

HEADERS_FREE=$(invoke_headers_helper)
if echo "$HEADERS_FREE" | jq -e 'has("X-License-Token") | not' >/dev/null 2>&1; then
  pass "Free: headersHelper omits X-License-Token"
else
  fail "Free: headersHelper unexpectedly emitted X-License-Token: $HEADERS_FREE"
fi

# ---------------------------------------------------------------------------
# 6. Scenario B — Pro tier (env-supplied token)
# ---------------------------------------------------------------------------
echo "--- scenario: Pro tier (env) ---"
LICENSE_TOKEN="AXON-shim-pro-test-token-must-be-32-chars-long-XYZW"
reset_captures
fire_pretooluse "echo benign-pro" >/dev/null
fire_posttooluse "echo benign-pro" "ok" >/dev/null

LIC_COUNT=$(captured_with_license_token)
TOTAL_COUNT=$(jq -s 'length' "$CAPTURE_FILE")
if [ "$LIC_COUNT" -ge 1 ] && [ "$LIC_COUNT" -eq "$TOTAL_COUNT" ]; then
  pass "Pro/env: ALL $TOTAL_COUNT captured request(s) carry X-License-Token"
else
  fail "Pro/env: $LIC_COUNT of $TOTAL_COUNT captured requests carried X-License-Token (expected all)"
fi

# Verify the token value is actually the one we set, not a placeholder.
TOKEN_OBSERVED=$(jq -s -r '.[0].headers["x-license-token"] // empty' "$CAPTURE_FILE")
[ "$TOKEN_OBSERVED" = "$LICENSE_TOKEN" ] && pass "Pro/env: captured token value matches AXONFLOW_LICENSE_TOKEN" \
  || fail "Pro/env: captured token '$TOKEN_OBSERVED' != env '$LICENSE_TOKEN'"

# headersHelper assertion for MCP path. Today's .mcp.json on Claude Code
# bypasses scripts/mcp-auth-headers.sh so the headersHelper output drops
# X-License-Token. Tracked as claude#56. Mark XFAIL until that lands so
# this test stays green and turns into a regression alarm post-fix.
HEADERS_PRO=$(invoke_headers_helper)
if echo "$HEADERS_PRO" | jq -e --arg t "$LICENSE_TOKEN" '."X-License-Token" == $t' >/dev/null 2>&1; then
  pass "Pro/env: headersHelper forwards X-License-Token (claude#56 fixed)"
else
  xfail "Pro/env: headersHelper drops X-License-Token (claude#56). got: $HEADERS_PRO"
fi

# ---------------------------------------------------------------------------
# 7. Scenario C — Pro tier (file-based token, mode 0600)
# ---------------------------------------------------------------------------
echo "--- scenario: Pro tier (file) ---"
LICENSE_TOKEN=""
TOKEN_FILE="$HOME_DIR/.config/axonflow/license-token.json"
TOKEN_VALUE="AXON-shim-pro-file-token-must-be-32-chars-PQRS"
# license-token.sh requires the file to be valid JSON with .token field.
printf '{"token":"%s"}' "$TOKEN_VALUE" > "$TOKEN_FILE"
chmod 0600 "$TOKEN_FILE"
reset_captures

fire_pretooluse "echo file-pro" >/dev/null
fire_posttooluse "echo file-pro" "ok" >/dev/null

LIC_COUNT=$(captured_with_license_token)
TOTAL_COUNT=$(jq -s 'length' "$CAPTURE_FILE")
if [ "$LIC_COUNT" -ge 1 ] && [ "$LIC_COUNT" -eq "$TOTAL_COUNT" ]; then
  pass "Pro/file: ALL $TOTAL_COUNT captured request(s) carry X-License-Token"
else
  fail "Pro/file: $LIC_COUNT of $TOTAL_COUNT captured requests carried X-License-Token (expected all)"
fi
TOKEN_OBSERVED=$(jq -s -r '.[0].headers["x-license-token"] // empty' "$CAPTURE_FILE")
[ "$TOKEN_OBSERVED" = "$TOKEN_VALUE" ] && pass "Pro/file: captured token value matches license-token.json .token" \
  || fail "Pro/file: captured token '$TOKEN_OBSERVED' != file '$TOKEN_VALUE'"

# Sanity: a 0644-permission token file is REJECTED with a stderr warning,
# the captured request omits X-License-Token (matches license-token.sh
# refusal contract).
chmod 0644 "$TOKEN_FILE"
reset_captures
fire_pretooluse "echo unsafe-perms" >/dev/null
LIC_COUNT=$(captured_with_license_token)
[ "$LIC_COUNT" -eq 0 ] && pass "Pro/file: token file with mode 0644 is refused (no X-License-Token on wire)" \
  || fail "Pro/file: unsafe-perms file STILL forwarded X-License-Token in $LIC_COUNT request(s)"
chmod 0600 "$TOKEN_FILE"

# ---------------------------------------------------------------------------
# 8. Scenario D — PreToolUse deny path
# ---------------------------------------------------------------------------
echo "--- scenario: PreToolUse deny path ---"
LICENSE_TOKEN="AXON-shim-pro-deny-token-must-be-32-chars-DENY"
reset_captures
DENY_OUT=$(fire_pretooluse "deny-me operation")

if echo "$DENY_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "Deny: PreToolUse output JSON includes permissionDecision=deny"
else
  fail "Deny: PreToolUse output didn't surface permissionDecision=deny: $DENY_OUT"
fi

# pre-tool-check.sh fires the blocked-attempt audit_tool_call as a backgrounded
# fire-and-forget curl (line 277) — the hook subshell exits before the request
# lands. Poll the capture file briefly so the test isn't racy.
AUDIT_BLOCKED=0
for _ in $(seq 1 30); do
  AUDIT_BLOCKED=$(captured_with_tool "audit_tool_call")
  [ "$AUDIT_BLOCKED" -ge 1 ] && break
  sleep 0.1
done
[ "$AUDIT_BLOCKED" -ge 1 ] && pass "Deny: blocked-attempt audit_tool_call captured" \
  || fail "Deny: blocked attempt did not emit audit_tool_call (got $AUDIT_BLOCKED)"

LIC_COUNT=$(captured_with_license_token)
[ "$LIC_COUNT" -ge 2 ] && pass "Deny: X-License-Token forwarded on both check_policy AND audit_tool_call" \
  || fail "Deny: X-License-Token only on $LIC_COUNT request(s) (expected ≥2)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== host-cli-shim summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
