#!/usr/bin/env bash
# Claude Code runtime E2E: audit_tool_call sends caller_name, not tool_type
# (axonflow-enterprise#2912, sub-issue of epic #2905).
#
# This is an outcome test, not a dispatch test. It drives the plugin's REAL
# hook scripts (pre-tool-check.sh + post-tool-audit.sh) — the two send sites
# that build the audit_tool_call MCP call — against a LIVE AxonFlow agent (no
# mocks), then asserts the resulting canonical `audit_logs` rows carry
# `policy_details.caller_name = "claude_code"` and NEVER `policy_details.tool_type`
# for new rows. The platform (axonflow-enterprise#2953) accepts caller_name as
# the correctly-named replacement for the misleadingly-named tool_type field —
# tool_type identified WHICH CLIENT called, not a tool classification.
#
# Two send sites are exercised, matching the two places this plugin was
# changed:
#   1. pre-tool-check.sh's blocked-call audit POST (fires when check_policy
#      denies a tool call — the "record the blocked attempt" branch).
#   2. post-tool-audit.sh's main PostToolUse audit POST (fires on every
#      executed tool call).
#
# Prereqs (skips cleanly otherwise):
#   AXONFLOW_ENDPOINT            self-hosted agent (default http://localhost:8080)
#   AXONFLOW_E2E_ENTERPRISE_AUTH base64(org_id:license_key)   [or]
#   AXONFLOW_E2E_ORG_ID + AXONFLOW_E2E_LICENSE_KEY            [or]
#   AXONFLOW_AUTH                pre-computed base64 Basic credential
#   AXONFLOW_E2E_DB_URL          psql-compatible URL to the platform DB (the
#                                audit-search API does not expose policy_details
#                                as a queryable-by-key surface for this assertion)
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

# Resolve enterprise Basic auth (support all three env shapes, same as
# ../developer-identity/test.sh).
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
  echo "SKIP: AXONFLOW_E2E_DB_URL not set (needed to read back audit_logs.policy_details)"
  exit 0
fi

# Unique per-run session so the assertions can't collide with prior rows.
SID="e2e-caller-name-$(date +%s)-$RANDOM"
echo "--- Driving governed hooks (session=$SID) ---"

export AXONFLOW_ENDPOINT="$ENDPOINT"
export AXONFLOW_AUTH="$AUTH"
export AXONFLOW_USER_EMAIL="e2e-caller-name-$(date +%s)-$RANDOM@example.com"
export AXONFLOW_TELEMETRY=off

# 1) PreToolUse on a destructive command → check_policy denies it → the
#    "record the blocked attempt" branch (pre-tool-check.sh ~line 492) fires
#    its own audit_tool_call POST with caller_name: "claude_code".
echo "{\"session_id\":\"$SID\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf / --no-preserve-root\"}}" \
  | "$PRE_HOOK" >/dev/null 2>&1

# 2) PostToolUse on an executed command → the main audit_tool_call POST
#    (post-tool-audit.sh ~line 154) fires with caller_name: "claude_code".
echo "{\"session_id\":\"$SID\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"tool_response\":{\"stdout\":\"hi\",\"exitCode\":0}}" \
  | "$POST_HOOK" >/dev/null 2>&1

query() { psql "$DB_URL" -tAc "$1" 2>/dev/null; }

# wait_count <count-sql> <min> — poll (1s interval, up to 20s) until the
# scalar count query returns >= min, then echo the final count. The audit
# writers are async (enqueue + background flush), so a fixed sleep flakes on
# a freshly-booted orchestrator whose first flush cycle lands late.
wait_count() {
  local sql="$1" min="$2" n=0 c=0
  while [ "$n" -lt 20 ]; do
    c=$(query "$sql")
    c="${c:-0}"
    [ "$c" -ge "$min" ] && break
    n=$((n + 1))
    sleep 1
  done
  printf '%s' "$c"
}

errors=0

# Wait for both tool_call_audit rows for this session to land before
# asserting (there should be exactly 2: the blocked-call audit from
# pre-tool-check.sh and the main audit from post-tool-audit.sh).
wait_count "SELECT count(*) FROM audit_logs WHERE request_type='tool_call_audit' AND session_id='$SID';" 2 >/dev/null

echo "--- audit_logs rows for this run ---"
query "SELECT policy_decision, policy_details FROM audit_logs WHERE request_type='tool_call_audit' AND session_id='$SID' ORDER BY timestamp;" || true

# The blocked-call audit row (from pre-tool-check.sh's "record the blocked
# attempt" branch): success:false, caller_name present, tool_type absent.
BLOCKED=$(query "SELECT count(*) FROM audit_logs WHERE request_type='tool_call_audit' AND session_id='$SID' AND policy_details->>'success'='false' AND policy_details->>'caller_name'='claude_code' AND NOT (policy_details ? 'tool_type');")
if [ "${BLOCKED:-0}" -ge 1 ]; then
  echo "PASS: pre-tool-check.sh blocked-call audit row carries caller_name=claude_code, no tool_type"
else
  echo "FAIL: no blocked-call tool_call_audit row with caller_name=claude_code and no tool_type for session_id=$SID"
  errors=$((errors + 1))
fi

# The main PostToolUse audit row (from post-tool-audit.sh): success:true,
# caller_name present, tool_type absent.
MAIN=$(query "SELECT count(*) FROM audit_logs WHERE request_type='tool_call_audit' AND session_id='$SID' AND policy_details->>'success'='true' AND policy_details->>'caller_name'='claude_code' AND NOT (policy_details ? 'tool_type');")
if [ "${MAIN:-0}" -ge 1 ]; then
  echo "PASS: post-tool-audit.sh main audit row carries caller_name=claude_code, no tool_type"
else
  echo "FAIL: no main tool_call_audit row with caller_name=claude_code and no tool_type for session_id=$SID"
  errors=$((errors + 1))
fi

# Belt-and-suspenders: tool_type must appear on NO row for this session — the
# plugin no longer sends it from either send site, so if the platform ever
# regressed to reading a stale field, this would catch it as a positive hit.
LEAKED_TOOL_TYPE=$(query "SELECT count(*) FROM audit_logs WHERE request_type='tool_call_audit' AND session_id='$SID' AND policy_details ? 'tool_type';")
if [ "${LEAKED_TOOL_TYPE:-1}" -eq 0 ]; then
  echo "PASS: no tool_call_audit row for this session carries the deprecated tool_type key"
else
  echo "FAIL: $LEAKED_TOOL_TYPE row(s) still carry policy_details.tool_type for session_id=$SID"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors caller_name-audit assertion(s) failed"
  exit 1
fi

echo ""
echo "PASS: caller_name replaces tool_type on both audit_tool_call send sites, verified on the real stack"
