#!/usr/bin/env bash
# V1 Plugin Pro envelope-surface runtime proof for the Claude Code plugin.
#
# Drives the plugin's REAL upgrade-prompt helper (`scripts/upgrade-prompt.sh`)
# against a REAL 429 envelope captured live from the REAL hosted agent at
# https://try.getaxonflow.com. No fixtures, no recorded responses — the
# envelope bytes that flow into `axonflow_handle_envelope_response` are
# the bytes the agent emitted to the wire seconds earlier.
#
# Why drive the helper directly (instead of running the full hook end-to-end):
#   The agent emits the V1 Plugin Pro 429 envelope on
#   `/api/v1/audit/tool-call` (and other apiAuthMiddleware-routed paths).
#   The plugin's hooks call `/api/v1/mcp-server` which authenticates via
#   `authenticateMCPServerRequest` and currently does NOT route through
#   apiAuthMiddleware — so a Free-tier-capped tenant calling MCP gets a
#   JSON-RPC -32001 result, not the 429 envelope. The plugin code is
#   correct (the helper handles both bare and JSON-RPC-wrapped envelopes
#   per the dual-shape parser in scripts/upgrade-prompt.sh) — what's
#   missing is server-side wiring of the daily-cap into MCP routing,
#   which is outside this lane. See PR body for the follow-up note.
#
# This test still proves what S3 lane is responsible for: the helper
# parses the locked V1 envelope shape, surfaces the wording to stderr,
# stamps a future-deadline throttle, and the throttle gate suppresses
# subsequent traffic.
#
# Usage:
#   AGENT_URL=https://try.getaxonflow.com bash test.sh
#
# Skips cleanly if curl/jq missing or AGENT_URL is unreachable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="${PLUGIN_DIR}/scripts/upgrade-prompt.sh"

AGENT_URL="${AGENT_URL:-https://try.getaxonflow.com}"
EXPECTED_WORDING="Pro raises this to 2,000/day"
EXPECTED_BUY_URL="https://buy.stripe.com/bJe28qbztcdVchjdkw8k800"

UTC_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE="$SCRIPT_DIR/EVIDENCE/$UTC_TS"
mkdir -p "$EVIDENCE"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: upgrade-prompt.sh missing at $HELPER"
  exit 1
fi

for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not on PATH"
    exit 0
  fi
done

if ! curl -sSf -o /dev/null --max-time 10 "${AGENT_URL}/health"; then
  echo "SKIP: agent /health not reachable at $AGENT_URL"
  exit 0
fi

# DB-direct seeding pre-flight. Loop-to-trip-cap on prod hits a per-IP
# burst limit (~20/min) before the 200/day daily cap, and the per-IP
# limiter response does NOT carry the V1 envelope (per
# feedback_429_no_upgrade_hint_is_conversion_gap.md). Seeding daily_usage
# to 200 lets call #1 return the V1 envelope cleanly.
REGION="${REGION:-us-east-1}"
STACK="${STACK:-}"
for tool in aws openssl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not on PATH (required for DB-seed flow)"
    exit 0
  fi
done
if ! python3 -c "import bcrypt" >/dev/null 2>&1; then
  echo "SKIP: python3 'bcrypt' module not installed (pip install bcrypt)"
  exit 0
fi
# bcrypt may live under the operator's user-site (~/Library/Python/...).
# Capture its path NOW, before we redirect HOME for the helper invocations
# downstream — otherwise db_register_tenant won't find the module when it
# hashes the synthetic tenant's secret.
BCRYPT_DIR=$(python3 -c "import bcrypt, os; print(os.path.dirname(os.path.dirname(bcrypt.__file__)))" 2>/dev/null)
if [ -n "$BCRYPT_DIR" ]; then
  export PYTHONPATH="${BCRYPT_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
fi

if [ -z "$STACK" ]; then
  case "$AGENT_URL" in
    *try-staging*) PREFIX='axonflow-community-saas-staging-2' ;;
    *try.getaxonflow*) PREFIX='axonflow-community-saas-2' ;;
    *) echo "SKIP: cannot auto-discover stack for AGENT_URL=$AGENT_URL"; exit 0 ;;
  esac
  STACK=$(aws cloudformation list-stacks --region "$REGION" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
    --query "StackSummaries[?starts_with(StackName, '$PREFIX') && !contains(StackName, 'staging-2') && !contains(StackName, 'alarm') && !contains(StackName, 'synth')].StackName" \
    --output text 2>/dev/null | tr '\t' '\n' | sort -r | head -1)
fi
if [ -z "$STACK" ] || [ "$STACK" = "None" ]; then
  echo "SKIP: could not auto-discover community-saas stack"
  exit 0
fi

ORCH_TASK=$(aws ecs list-tasks --region "$REGION" --cluster "${STACK}-cluster" \
  --service-name "${STACK}-orchestrator-service" --query 'taskArns[0]' --output text 2>/dev/null)
if [ -z "$ORCH_TASK" ] || [ "$ORCH_TASK" = "None" ]; then
  echo "SKIP: no running orchestrator task in cluster ${STACK}-cluster"
  exit 0
fi
DB_HOST=$(aws rds describe-db-instances --region "$REGION" \
  --query "DBInstances[?DBInstanceIdentifier == '${STACK}-db'].Endpoint.Address" \
  --output text 2>/dev/null | head -1)
if [ -z "$DB_HOST" ] || [ "$DB_HOST" = "None" ]; then
  echo "SKIP: could not resolve DB_HOST for $STACK"
  exit 0
fi
DB_PASS=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "${STACK}-db-password" --query SecretString --output text 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])' 2>/dev/null)
if [ -z "$DB_PASS" ]; then
  echo "SKIP: could not resolve DB_PASS from ${STACK}-db-password SM secret"
  exit 0
fi

DB_LIB="${PLUGIN_DIR}/../axonflow-enterprise/runtime-e2e/v1_paid_tier_staging/lib/db_helpers.sh"
if [ ! -f "$DB_LIB" ]; then
  echo "SKIP: db_helpers.sh not found at $DB_LIB (sibling axonflow-enterprise checkout required)"
  exit 0
fi
export STACK ORCH_TASK DB_HOST DB_PASS REGION
# shellcheck disable=SC1090
source "$DB_LIB"

# Hermetic plugin cache — set XDG_CACHE_HOME (which upgrade-prompt.sh
# honours) so the helper writes its throttle file to a tmp path. We do
# NOT redirect HOME — that would drop the operator's AWS credentials and
# break the db_helpers.sh ECS-exec calls.
TEST_CACHE=$(mktemp -d -t axonflow-claude-v1env.XXXXXX)
export XDG_CACHE_HOME="$TEST_CACHE"

TENANT="cs_e2e_claude_envelope_$(date -u +%s)"
SECRET="testpass$(openssl rand -hex 4)"
cleanup() {
  rm -rf "$TEST_CACHE" 2>/dev/null || true
  if [ -n "${TENANT:-}" ]; then
    db_run_sql "DELETE FROM community_saas_daily_usage WHERE tenant_id = '${TENANT}';" >/dev/null 2>&1 || true
    db_run_sql "DELETE FROM community_saas_registrations WHERE tenant_id = '${TENANT}';" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "AGENT_URL=$AGENT_URL"
echo "STACK=$STACK"
echo "TENANT=$TENANT"
echo "TEST_CACHE=$TEST_CACHE"
echo "EVIDENCE=$EVIDENCE"

# Preflight: install psql in orchestrator container (apk-based; wiped on
# task restart per feedback_ecs_exec_apk_psql_for_db_access.md).
echo "Preflight: install postgresql-client in orchestrator task ${ORCH_TASK##*/}"
aws ecs execute-command --region "$REGION" \
  --cluster "${STACK}-cluster" --task "$ORCH_TASK" --container orchestrator \
  --interactive --command "sh -c 'apk add --no-cache postgresql-client >/dev/null 2>&1 && echo psql-installed'" \
  2>&1 | grep -E 'psql-installed|already installed|^ERROR' | head -3 || true

# ---------------------------------------------------------------------------
# Step 1: register synthetic Free-tier tenant via DB direct insert. Bypasses
# the per-IP 5/hr rate limit on /api/v1/register and gives us a clean
# tenant we can scope the daily_usage seed to without polluting other
# tenants on the same stack.
# ---------------------------------------------------------------------------
echo "Step 1: register synthetic tenant via DB direct insert"
if ! db_register_tenant "$TENANT" "$SECRET" "v1-pro-claude-envelope-e2e"; then
  echo "FAIL: tenant registration"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: seed daily_usage at the Free cap (200) so the next governed call
# from this tenant trips writeRateLimitError → V1 envelope. The seed runs
# inside the orchestrator container so the rate limiter sees a fully-
# committed row before the test request lands.
# ---------------------------------------------------------------------------
echo "Step 2: seed daily_usage = 200 (= Free cap, next call returns the V1 envelope)"
if ! db_set_daily_usage "$TENANT" 200; then
  echo "FAIL: daily_usage seeding"
  exit 1
fi
USAGE=$(db_get_daily_usage "$TENANT")
echo "  daily_usage=$USAGE"
if [ "$USAGE" != "200" ]; then
  echo "FAIL: daily_usage seed verification (got '$USAGE', want 200)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: one call to /api/v1/audit/tool-call — apiAuthMiddleware sees
# daily_usage at the cap and emits the V1 Plugin Pro 429 envelope.
# ---------------------------------------------------------------------------
echo "Step 3: capture wire envelope from /api/v1/audit/tool-call (expect 429 V1 envelope)"
PAYLOAD='{"tool_name":"v1_envelope_e2e","caller_name":"runtime_e2e","tool_type":"runtime_e2e","input":{"probe":"daily_quota_envelope"},"success":true}'
TRIP_LOG="$EVIDENCE/trip_loop.log"
ENVELOPE_BODY="$EVIDENCE/envelope_body.json"
ENVELOPE_HEADERS="$EVIDENCE/envelope_headers.txt"
TRIP_HTTP=$(curl -sS -D "$ENVELOPE_HEADERS" -o "$ENVELOPE_BODY" -w '%{http_code}' \
  -X POST "${AGENT_URL}/api/v1/audit/tool-call" \
  -u "${TENANT}:${SECRET}" -H 'Content-Type: application/json' \
  --max-time 10 \
  -d "$PAYLOAD" 2>/dev/null) || TRIP_HTTP="000"
echo "1 $TRIP_HTTP" >"$TRIP_LOG"
if [ "$TRIP_HTTP" != "429" ]; then
  echo "FAIL: expected 429 from capped tenant, got $TRIP_HTTP"
  cat "$ENVELOPE_BODY" 2>/dev/null
  exit 1
fi

# Pretty-print envelope for evidence.
jq . "$ENVELOPE_BODY" >"$EVIDENCE/envelope_body_pretty.json" 2>/dev/null \
  || cp "$ENVELOPE_BODY" "$EVIDENCE/envelope_body_pretty.json"

# ---------------------------------------------------------------------------
# Step 4: assert the 429 carries the locked V1 envelope shape (sanity check
# on the wire format we're handing to the helper).
# ---------------------------------------------------------------------------
echo "Step 4: assert wire envelope shape"
PASS=true
fail() { echo "FAIL: $1"; PASS=false; }

[ "$(jq -r '.limit_type // empty' "$ENVELOPE_BODY")" = "daily_quota" ] || fail "envelope.limit_type not 'daily_quota'"
[ "$(jq -r '.tier // empty' "$ENVELOPE_BODY")" = "Free" ] || fail "envelope.tier not 'Free'"
WORD=$(jq -r '.upgrade.wording // empty' "$ENVELOPE_BODY")
echo "$WORD" | grep -qF "$EXPECTED_WORDING" || fail "envelope.upgrade.wording missing locked phrase '$EXPECTED_WORDING'"
[ "$(jq -r '.upgrade.buy_url // empty' "$ENVELOPE_BODY")" = "$EXPECTED_BUY_URL" ] || fail "envelope.upgrade.buy_url unexpected"

H_TIER=$(grep -i '^x-axonflow-tier-limit:' "$ENVELOPE_HEADERS" | tr -d '\r' | awk '{print $2}')
[ "$H_TIER" = "daily_quota" ] || fail "X-Axonflow-Tier-Limit header missing/wrong: '$H_TIER'"
H_RETRY=$(grep -i '^retry-after:' "$ENVELOPE_HEADERS" | tr -d '\r' | awk '{print $2}')
{ [ -n "$H_RETRY" ] && [[ "$H_RETRY" =~ ^[0-9]+$ ]]; } || fail "Retry-After header missing/non-numeric: '$H_RETRY'"

# ---------------------------------------------------------------------------
# Step 5: drive the REAL plugin helper against the captured wire envelope.
# This exercises the actual code path the plugin will run when an envelope
# arrives.
# ---------------------------------------------------------------------------
echo "Step 5: source upgrade-prompt.sh and call axonflow_handle_envelope_response"
HELPER_OUT="$EVIDENCE/helper_stdout.log"
HELPER_ERR="$EVIDENCE/helper_stderr.log"
(
  # shellcheck disable=SC1090
  . "$HELPER"
  axonflow_handle_envelope_response "$TRIP_HTTP" "$ENVELOPE_BODY" "$ENVELOPE_HEADERS"
) >"$HELPER_OUT" 2>"$HELPER_ERR"
HELPER_RC=$?
echo "  helper rc=$HELPER_RC stdout=$(wc -c <"$HELPER_OUT") stderr=$(wc -c <"$HELPER_ERR")"

if [ "$HELPER_RC" -ne 0 ]; then
  fail "axonflow_handle_envelope_response rc=$HELPER_RC (expected 0 — envelope detected)"
fi

if ! grep -qF "$EXPECTED_WORDING" "$HELPER_ERR"; then
  fail "helper stderr missing locked wording '$EXPECTED_WORDING'"
  echo "--- helper_stderr.log ---"
  cat "$HELPER_ERR"
  echo "--- end ---"
fi

if ! grep -qF "$EXPECTED_BUY_URL" "$HELPER_ERR"; then
  fail "helper stderr missing buy URL '$EXPECTED_BUY_URL'"
fi

if [ -s "$HELPER_OUT" ]; then
  fail "helper emitted bytes on stdout (stdout is reserved for the hook protocol)"
  cat "$HELPER_OUT"
fi

THROTTLE_FILE="$TEST_CACHE/axonflow/throttle-until"
if [ ! -f "$THROTTLE_FILE" ]; then
  fail "throttle file not stamped at $THROTTLE_FILE"
else
  cp "$THROTTLE_FILE" "$EVIDENCE/throttle-until.txt"
  THROTTLE_EPOCH=$(awk 'NR==1 {print $1}' "$THROTTLE_FILE")
  NOW=$(date -u +%s)
  if [ -z "$THROTTLE_EPOCH" ] || ! [[ "$THROTTLE_EPOCH" =~ ^[0-9]+$ ]] || [ "$THROTTLE_EPOCH" -le "$NOW" ]; then
    fail "throttle deadline not in future (got '$THROTTLE_EPOCH'; now=$NOW)"
  else
    echo "  throttle deadline: $THROTTLE_EPOCH (in $((THROTTLE_EPOCH - NOW))s)"
  fi
fi

# ---------------------------------------------------------------------------
# Step 6: prove the throttle gate suppresses subsequent traffic. Source
# the helper a second time and call axonflow_throttle_active — it must
# return 0 (in throttle window).
# ---------------------------------------------------------------------------
echo "Step 6: assert axonflow_throttle_active gates subsequent calls"
(
  # shellcheck disable=SC1090
  . "$HELPER"
  axonflow_throttle_active
) >/dev/null 2>"$EVIDENCE/throttle_check_stderr.log"
THROTTLE_RC=$?
if [ "$THROTTLE_RC" -ne 0 ]; then
  fail "axonflow_throttle_active rc=$THROTTLE_RC after envelope handled (expected 0 — gate active)"
fi

# ---------------------------------------------------------------------------
# Step 7: prove the once-per-day stamp suppresses the prompt on the second
# fire. Re-invoke the handler — the throttle file is already there, the
# wording must NOT be re-emitted to stderr.
# ---------------------------------------------------------------------------
echo "Step 7: re-invoke handler — wording must not re-emit (once-per-day gate)"
HELPER_ERR2="$EVIDENCE/helper_stderr_run2.log"
(
  # shellcheck disable=SC1090
  . "$HELPER"
  axonflow_handle_envelope_response "$TRIP_HTTP" "$ENVELOPE_BODY" "$ENVELOPE_HEADERS"
) >/dev/null 2>"$HELPER_ERR2"
if grep -qF "$EXPECTED_WORDING" "$HELPER_ERR2"; then
  fail "wording was re-emitted on second handler invocation — once-per-day stamp not honoured"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
{
  echo "Claude plugin V1 Plugin Pro envelope-surface runtime proof — $UTC_TS"
  echo "AGENT_URL=$AGENT_URL"
  echo "TENANT=$TENANT"
  echo "Cap tripped at request: $(awk 'END{print $1}' "$TRIP_LOG")"
  echo "Helper rc: $HELPER_RC"
  echo "Throttle gate rc: $THROTTLE_RC"
  echo "Result: $($PASS && echo PASS || echo FAIL)"
} | tee "$EVIDENCE/summary.txt"

if $PASS; then
  echo
  echo "PASS — Claude plugin surfaces the V1 Plugin Pro envelope and honours back-off"
  exit 0
else
  echo
  echo "FAIL — see $EVIDENCE/ for evidence"
  exit 1
fi
