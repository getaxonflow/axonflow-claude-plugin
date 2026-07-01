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

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors identity-outcome assertion(s) failed"
  exit 1
fi

echo ""
echo "PASS: developer identity end-to-end — user_email + session_id populated on both governed planes"
