#!/usr/bin/env bash
# Install-to-use smoke gate harness.
#
# Stages the plugin to a clean tmp dir (mirroring what `claude plugin
# install` would copy), validates the file list and hooks.json paths
# resolve, spawns a stub MCP server on a random port, and exercises the
# pre-tool-check.sh hook against it for both deny (SQLi) and allow
# (benign) paths. Asserts:
#
#   - Required files present in the staged install
#   - hooks.json hooks point to scripts that exist post-install
#   - Wire-shape Plugin Batch 1 fields surface in the deny output
#     (decision_id / risk_level / override_available)
#   - Allow path returns silent (no output)
#
# Catches the class of regressions the existing test-hooks.sh misses
# because it runs against the source tree:
#   - hooks.json paths broken after install (wrong relative path)
#   - Required files missing from the install payload
#   - Scripts referencing files relative to source tree that don't
#     exist in the installed location
#
# No external network or live AxonFlow stack required.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STAGE_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t install-smoke)
LOG_DIR="${STAGE_DIR}/.logs"
mkdir -p "$LOG_DIR"

cleanup() {
  if [ -n "${STUB_PID:-}" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

# 1. Stage the plugin's install payload.
echo "stage to $STAGE_DIR"
mkdir -p "$STAGE_DIR/.claude-plugin" "$STAGE_DIR/hooks" "$STAGE_DIR/scripts"
cp -p "$PLUGIN_DIR/.claude-plugin/plugin.json" "$STAGE_DIR/.claude-plugin/" \
  || fail "missing .claude-plugin/plugin.json"
cp -p "$PLUGIN_DIR/.mcp.json" "$STAGE_DIR/" \
  || fail "missing .mcp.json"
cp -p "$PLUGIN_DIR/hooks/hooks.json" "$STAGE_DIR/hooks/" \
  || fail "missing hooks/hooks.json"
cp -p "$PLUGIN_DIR/scripts/"*.sh "$STAGE_DIR/scripts/" \
  || fail "missing scripts/*.sh"
chmod +x "$STAGE_DIR/scripts/"*.sh

# 2. Validate file list.
for f in .claude-plugin/plugin.json .mcp.json hooks/hooks.json \
         scripts/pre-tool-check.sh scripts/post-tool-audit.sh \
         scripts/telemetry-ping.sh scripts/mcp-auth-headers.sh \
         scripts/license-token.sh scripts/login.sh \
         scripts/recover.sh scripts/recover-verify.sh \
         scripts/status.sh; do
  if [ -f "$STAGE_DIR/$f" ]; then pass "staged $f"
  else fail "missing $f after stage"
  fi
done

# 2b. status.sh smoke — invoke the staged script against an empty
# AXONFLOW_CONFIG_DIR (no registration file, no license token) and
# assert the Free-tier output shape PLUS that no full-token-shaped
# string ever appears in stdout. The latter is the regression guard
# axonflow-codex-plugin#41 added — /axonflow-status is a screen-share
# surface, the bearer credential must never appear there.
STATUS_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t axonflow-status)
STATUS_OUT=$(AXONFLOW_LICENSE_TOKEN='' \
  HOME="$STATUS_TMP" \
  AXONFLOW_CONFIG_DIR="$STATUS_TMP/empty" \
  "$STAGE_DIR/scripts/status.sh" 2>/dev/null || true)
if echo "$STATUS_OUT" | grep -q "tier=Free"; then pass "status.sh Free-tier path"
else fail "status.sh Free-tier path missing 'tier=Free': $STATUS_OUT"
fi
if echo "$STATUS_OUT" | grep -q "license_token=unset"; then pass "status.sh prints license_token=unset on Free"
else fail "status.sh missing 'license_token=unset': $STATUS_OUT"
fi
if echo "$STATUS_OUT" | grep -q "upgrade_url="; then pass "status.sh prints upgrade_url on Free"
else fail "status.sh missing upgrade_url: $STATUS_OUT"
fi
# Regression guard for token-leak (mirrors codex#41 Test 6c).
FAKE_TOKEN="AXON-fake-status-test-token-must-be-32-chars-long-XYZW"
PRO_OUT=$(AXONFLOW_LICENSE_TOKEN="$FAKE_TOKEN" \
  HOME="$STATUS_TMP" \
  AXONFLOW_CONFIG_DIR="$STATUS_TMP/empty" \
  "$STAGE_DIR/scripts/status.sh" 2>/dev/null || true)
if echo "$PRO_OUT" | grep -q "tier=Pro"; then pass "status.sh Pro-tier path"
else fail "status.sh Pro-tier path missing 'tier=Pro': $PRO_OUT"
fi
if echo "$PRO_OUT" | grep -qF "$FAKE_TOKEN"; then
  fail "status.sh leaked the full token to stdout — bearer credential MUST be redacted"
else pass "status.sh redacts full license token (no full-token leak)"
fi
if echo "$PRO_OUT" | grep -q "AXON-\.\.\.XYZW"; then pass "status.sh shows last-4-chars preview"
else fail "status.sh missing last-4-chars token preview: $PRO_OUT"
fi
rm -rf "$STATUS_TMP"

# 3. Validate hooks.json hook command paths resolve to staged scripts.
HOOKS_JSON="$STAGE_DIR/hooks/hooks.json"
if [ ! -f "$HOOKS_JSON" ]; then
  fail "hooks.json not present; bailing"; exit 1
fi
# Extract every command path referenced in hooks.json (heuristic:
# any "command" field referencing a *.sh script).
SCRIPTS_REFERENCED=$(jq -r '..|objects|select(.command)|.command' "$HOOKS_JSON" 2>/dev/null \
  | grep -oE '\${CLAUDE_PLUGIN_ROOT}/[^ "]*' || true)
for cmd in $SCRIPTS_REFERENCED; do
  rel=${cmd#'${CLAUDE_PLUGIN_ROOT}/'}
  if [ -f "$STAGE_DIR/$rel" ] && [ -x "$STAGE_DIR/$rel" ]; then
    pass "hooks.json -> $rel resolves and is executable"
  else
    fail "hooks.json references $rel which is missing or not executable in stage"
  fi
done

# 4. Spawn stub MCP server.
STUB_LOG="$LOG_DIR/stub.log"
python3 "$PLUGIN_DIR/tests/install-smoke/stub-server.py" 0 >"$STUB_LOG" 2>&1 &
STUB_PID=$!
# Wait up to 5s for the stub to print PORT=<n>. set -e doesn't play well
# with pipefail + grep returning 1 on no-match, so disable it briefly.
set +e
PORT=""
for _ in $(seq 1 50); do
  PORT=$(grep -oE 'PORT=[0-9]+' "$STUB_LOG" 2>/dev/null | head -1 | cut -d= -f2)
  if [ -n "$PORT" ]; then break; fi
  sleep 0.1
done
set -e
if [ -z "$PORT" ]; then fail "stub-server failed to start; log: $(cat "$STUB_LOG")"; exit 1; fi
pass "stub-server listening on 127.0.0.1:$PORT"

# 5. Run pre-tool-check.sh from STAGE_DIR (not source) against stub.
HOOK="$STAGE_DIR/scripts/pre-tool-check.sh"
ENDPOINT="http://127.0.0.1:$PORT"

# Deny case: SQLi statement.
# AXONFLOW_TELEMETRY=off suppresses the backgrounded telemetry-ping.sh that
# pre-tool-check.sh fires via &. Without this, every install-smoke run leaks
# a real ping to checkpoint.getaxonflow.com.
DENY_INPUT='{"tool_name":"Bash","tool_input":{"command":"DROP TABLE users; --"}}'
DENY_OUTPUT=$(echo "$DENY_INPUT" | AXONFLOW_ENDPOINT="$ENDPOINT" AXONFLOW_TELEMETRY=off "$HOOK" 2>/dev/null || true)
if echo "$DENY_OUTPUT" | grep -q '"deny"'; then pass "deny path returns deny decision"
else fail "deny path missing deny decision: $DENY_OUTPUT"
fi
if echo "$DENY_OUTPUT" | grep -q "decision: dec_test_deny_001"; then pass "deny path surfaces decision_id"
else fail "deny path missing decision_id"
fi
if echo "$DENY_OUTPUT" | grep -q "risk: high"; then pass "deny path surfaces risk_level"
else fail "deny path missing risk_level"
fi
if echo "$DENY_OUTPUT" | grep -q "override available"; then pass "deny path surfaces override_available"
else fail "deny path missing override_available"
fi

# Allow case: benign statement.
ALLOW_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
ALLOW_OUTPUT=$(echo "$ALLOW_INPUT" | AXONFLOW_ENDPOINT="$ENDPOINT" AXONFLOW_TELEMETRY=off "$HOOK" 2>/dev/null || true)
if [ -z "$ALLOW_OUTPUT" ]; then pass "allow path returns silent (no output)"
else fail "allow path produced unexpected output: $ALLOW_OUTPUT"
fi

# 6. Summary.
echo
echo "Pass: $PASS"
echo "Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
