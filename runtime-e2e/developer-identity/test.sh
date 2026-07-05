#!/usr/bin/env bash
# Claude Code runtime E2E: per-developer + per-session identity OUTCOME test
# (issue #2753/#2754).
#
# This is an outcome test, not a dispatch test. It drives the plugin's REAL hook
# scripts (pre-tool-check.sh + post-tool-audit.sh) — the runtime components that
# inject identity on every governed tool call — against a LIVE AxonFlow agent
# (no mocks), then asserts the resulting canonical `audit_logs` rows carry the
# real developer email AND the AI-tool session id in their first-class columns.
#
# Why the hooks and not `claude`: identity (X-User-Email / X-Session-Id) is
# emitted by the plugin's hook layer + .mcp.json headersHelper, not by any MCP
# tool the agent chooses. Firing the hooks the way Claude Code fires them — with
# the exact PreToolUse/PostToolUse stdin JSON — exercises the identical
# production code path (resolve identity → attach headers → agent persists) and
# lets us assert the DB outcome deterministically. The agent + orchestrator are
# the real stack; there are no stubs.
#
# Enterprise auth (cite feedback-runtime-e2e-must-support-enterprise-auth): the
# harness reads AXONFLOW_AUTH / AXONFLOW_E2E_ENTERPRISE_AUTH (Basic) so it works
# against a real in-VPC Enterprise agent, not only a permissive community stack.
#
# Prereqs (skips cleanly otherwise):
#   AXONFLOW_ENDPOINT            self-hosted agent (default http://localhost:8080)
#   AXONFLOW_E2E_ENTERPRISE_AUTH base64(org_id:license_key)   [or]
#   AXONFLOW_E2E_ORG_ID + AXONFLOW_E2E_LICENSE_KEY            [or]
#   AXONFLOW_AUTH                pre-computed base64 Basic credential
#   AXONFLOW_E2E_DB_URL          psql-compatible URL to the platform DB (to read
#                                back audit_logs.session_id — the audit-search
#                                API does not expose the new column yet)
#   jq, curl, psql on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"
POST_HOOK="$PLUGIN_DIR/scripts/post-tool-audit.sh"

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"

for bin in jq curl psql; do
  command -v "$bin" >/dev/null 2>&1 || { echo "SKIP: $bin not on PATH"; exit 0; }
done
if ! curl -sSf -o /dev/null --max-time 5 "$ENDPOINT/health"; then
  echo "SKIP: AxonFlow agent not reachable at $ENDPOINT/health"
  exit 0
fi

# Resolve enterprise Basic auth (support all three env shapes).
AUTH="${AXONFLOW_AUTH:-}"
if [ -z "$AUTH" ] && [ -n "${AXONFLOW_E2E_ENTERPRISE_AUTH:-}" ]; then
  AUTH="$AXONFLOW_E2E_ENTERPRISE_AUTH"
fi
if [ -z "$AUTH" ] && [ -n "${AXONFLOW_E2E_ORG_ID:-}" ] && [ -n "${AXONFLOW_E2E_LICENSE_KEY:-}" ]; then
  AUTH="$(printf '%s:%s' "$AXONFLOW_E2E_ORG_ID" "$AXONFLOW_E2E_LICENSE_KEY" | base64 | tr -d '\n')"
fi
if [ -z "$AUTH" ]; then
  echo "SKIP: no agent credential (set AXONFLOW_AUTH / AXONFLOW_E2E_ENTERPRISE_AUTH / AXONFLOW_E2E_ORG_ID+LICENSE_KEY)"
  exit 0
fi
DB_URL="${AXONFLOW_E2E_DB_URL:-}"
if [ -z "$DB_URL" ]; then
  echo "SKIP: AXONFLOW_E2E_DB_URL not set (needed to read back audit_logs.session_id)"
  exit 0
fi

# Unique per-run identity so the assertions can't collide with prior rows.
EMAIL="e2e-dev-$(date +%s)-$RANDOM@example.com"
SID="e2e-session-$(date +%s)-$RANDOM"
echo "--- Driving governed hooks as developer=$EMAIL session=$SID ---"

export AXONFLOW_ENDPOINT="$ENDPOINT"
export AXONFLOW_AUTH="$AUTH"
export AXONFLOW_USER_EMAIL="$EMAIL"
export AXONFLOW_TELEMETRY=off

# 1) PreToolUse on a destructive command → check_policy blocks → the agent
#    writes a canonical mcp_check_policy row carrying user_email + session_id.
echo "{\"session_id\":\"$SID\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf / --no-preserve-root\"}}" \
  | "$PRE_HOOK" >/dev/null 2>&1

# 2) PostToolUse on an executed command → audit_tool_call → the orchestrator
#    writes a tool_call_audit row carrying user_email + session_id.
echo "{\"session_id\":\"$SID\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"tool_response\":{\"stdout\":\"hi\",\"exitCode\":0}}" \
  | "$POST_HOOK" >/dev/null 2>&1

# Give the async audit writers time to flush.
sleep 4

query() { psql "$DB_URL" -tAc "$1" 2>/dev/null; }

errors=0

# The check_policy (PreToolUse) row: user_email + session_id both populated.
CHK=$(query "SELECT count(*) FROM audit_logs WHERE request_type='mcp_check_policy' AND user_email='$EMAIL' AND session_id='$SID';")
if [ "${CHK:-0}" -ge 1 ]; then
  echo "PASS: check_policy row carries user_email + session_id"
else
  echo "FAIL: no mcp_check_policy row with user_email=$EMAIL AND session_id=$SID"
  errors=$((errors + 1))
fi

# The audit_tool_call (PostToolUse) row: user_email + session_id both populated.
AUD=$(query "SELECT count(*) FROM audit_logs WHERE request_type='tool_call_audit' AND user_email='$EMAIL' AND session_id='$SID';")
if [ "${AUD:-0}" -ge 1 ]; then
  echo "PASS: audit_tool_call row carries user_email + session_id"
else
  echo "FAIL: no tool_call_audit row with user_email=$EMAIL AND session_id=$SID"
  errors=$((errors + 1))
fi

echo "--- audit_logs rows for this run ---"
query "SELECT request_type, policy_decision, user_email, session_id FROM audit_logs WHERE session_id='$SID' ORDER BY timestamp;" || true

# ---------------------------------------------------------------------------
# #2836 leg 2: identity-ABSENT — the real-world unconfigured-fleet state (no
# AXONFLOW_USER_EMAIL, no git identity, non-repo cwd). The hooks must still
# send governed traffic with the X-User-Email header OMITTED, the agent must
# degrade to its client-scoped identity (never a blank/NULL user_email), and
# the once-per-day stderr diagnostic must fire so the degradation is VISIBLE —
# the silent version of this state is exactly how epic #2832 went unnoticed.
# ---------------------------------------------------------------------------
SID_ABSENT="e2e-session-absent-$(date +%s)-$RANDOM"
ABSENT_HOME="$(mktemp -d)"
HOOK_ERR="$(mktemp)"
trap 'rm -rf "$ABSENT_HOME" "$HOOK_ERR"' EXIT
echo "--- Driving governed hooks with NO identity (session=$SID_ABSENT) ---"

echo "{\"session_id\":\"$SID_ABSENT\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf / --no-preserve-root\"}}" \
  | ( cd "$ABSENT_HOME" && env -u AXONFLOW_USER_EMAIL HOME="$ABSENT_HOME" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      "$PRE_HOOK" >/dev/null 2>>"$HOOK_ERR" )
echo "{\"session_id\":\"$SID_ABSENT\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"tool_response\":{\"stdout\":\"hi\",\"exitCode\":0}}" \
  | ( cd "$ABSENT_HOME" && env -u AXONFLOW_USER_EMAIL HOME="$ABSENT_HOME" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      "$POST_HOOK" >/dev/null 2>>"$HOOK_ERR" )
sleep 4

# Governed traffic still flowed (identity-absent must never drop governance).
ROWS=$(query "SELECT count(*) FROM audit_logs WHERE session_id='$SID_ABSENT';")
if [ "${ROWS:-0}" -ge 1 ]; then
  echo "PASS: identity-absent — governed rows still written (count=$ROWS)"
else
  echo "FAIL: identity-absent — no audit_logs rows for session_id=$SID_ABSENT"
  errors=$((errors + 1))
fi

# Degradation contract: client-scoped attribution, never blank/NULL and never
# a leaked test identity.
BLANK=$(query "SELECT count(*) FROM audit_logs WHERE session_id='$SID_ABSENT' AND (user_email IS NULL OR user_email='');")
LEAK=$(query "SELECT count(*) FROM audit_logs WHERE session_id='$SID_ABSENT' AND user_email LIKE '%@example.com';")
if [ "${ROWS:-0}" -ge 1 ] && [ "${BLANK:-1}" -eq 0 ] && [ "${LEAK:-1}" -eq 0 ]; then
  echo "PASS: identity-absent — rows degrade to the client-scoped id (no blank, no leak)"
else
  echo "FAIL: identity-absent degradation broken (blank=$BLANK leak=$LEAK):"
  query "SELECT request_type, user_email FROM audit_logs WHERE session_id='$SID_ABSENT';" || true
  errors=$((errors + 1))
fi

# The visibility half of #2836: the REAL hook told the operator WHY.
if grep -q "No developer identity resolved" "$HOOK_ERR"; then
  echo "PASS: identity-absent — stderr diagnostic fired"
else
  echo "FAIL: identity-absent — diagnostic missing from hook stderr: $(cat "$HOOK_ERR")"
  errors=$((errors + 1))
fi

# ---------------------------------------------------------------------------
# #2836 leg 3: git-fallback — no AXONFLOW_USER_EMAIL, but a git user.email is
# configured. The hardened resolution (merged → --global read) must carry the
# git identity through the REAL hooks into the canonical audit rows.
# ---------------------------------------------------------------------------
SID_GIT="e2e-session-git-$(date +%s)-$RANDOM"
GIT_EMAIL="e2e-git-$(date +%s)-$RANDOM@example.com"
GIT_HOME="$(mktemp -d)"
GCFG="$GIT_HOME/gitconfig"
printf '[user]\n\temail = %s\n' "$GIT_EMAIL" > "$GCFG"
trap 'rm -rf "$ABSENT_HOME" "$HOOK_ERR" "$GIT_HOME"' EXIT
echo "--- Driving governed hooks with git-only identity ($GIT_EMAIL, session=$SID_GIT) ---"

echo "{\"session_id\":\"$SID_GIT\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf / --no-preserve-root\"}}" \
  | ( cd "$GIT_HOME" && env -u AXONFLOW_USER_EMAIL HOME="$GIT_HOME" \
      GIT_CONFIG_GLOBAL="$GCFG" GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      "$PRE_HOOK" >/dev/null 2>&1 )
echo "{\"session_id\":\"$SID_GIT\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"tool_response\":{\"stdout\":\"hi\",\"exitCode\":0}}" \
  | ( cd "$GIT_HOME" && env -u AXONFLOW_USER_EMAIL HOME="$GIT_HOME" \
      GIT_CONFIG_GLOBAL="$GCFG" GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      "$POST_HOOK" >/dev/null 2>&1 )
sleep 4

GIT_CHK=$(query "SELECT count(*) FROM audit_logs WHERE request_type='mcp_check_policy' AND user_email='$GIT_EMAIL' AND session_id='$SID_GIT';")
if [ "${GIT_CHK:-0}" -ge 1 ]; then
  echo "PASS: git-fallback — check_policy row carries the git user.email"
else
  echo "FAIL: git-fallback — no mcp_check_policy row with user_email=$GIT_EMAIL AND session_id=$SID_GIT"
  errors=$((errors + 1))
fi
GIT_AUD=$(query "SELECT count(*) FROM audit_logs WHERE request_type='tool_call_audit' AND user_email='$GIT_EMAIL' AND session_id='$SID_GIT';")
if [ "${GIT_AUD:-0}" -ge 1 ]; then
  echo "PASS: git-fallback — audit_tool_call row carries the git user.email"
else
  echo "FAIL: git-fallback — no tool_call_audit row with user_email=$GIT_EMAIL AND session_id=$SID_GIT"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors identity-outcome assertion(s) failed"
  exit 1
fi

echo ""
echo "PASS: developer identity end-to-end — env identity, identity-absent degradation + diagnostic, and git fallback all verified on the real stack"
