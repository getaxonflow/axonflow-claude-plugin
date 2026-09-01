#!/usr/bin/env bash
# license_tier heartbeat matrix — drives the REAL scripts/telemetry-ping.sh.
#
# Two halves, and the second is the load-bearing one:
#
#   ROUND-TRIP    every tier value the platform can answer with reaches the
#                 wire byte-for-byte unchanged. The plugin relays; it does not
#                 normalize, case-fold, or flatten a tier it has not heard of.
#
#   FAIL OPEN     every way the probe can fail — unreachable, 4xx, 5xx,
#                 malformed, empty, wrong-typed, absent, over-long, too slow —
#                 leaves the heartbeat itself intact, the key ABSENT (not
#                 "unknown", not null, not empty), the exit code 0, and both
#                 stdout and stderr silent. Telemetry enrichment must never
#                 be able to degrade the hook it rides on.
#
# Invoked with no argument it tests the shipped script. It accepts a path so
# mutation_gate.sh can point it at a deliberately-broken copy and require it
# to go red — a matrix that cannot fail is not evidence.
#
# Usage: run.sh [path-to-telemetry-ping.sh]
# Exit:  0 all assertions passed · 1 an assertion failed · 0 + SKIP: tools absent

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
PING_SCRIPT="${1:-$PLUGIN_DIR/scripts/telemetry-ping.sh}"

for tool in bash curl jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not on PATH"
    exit 0
  fi
done

if [ ! -f "$PING_SCRIPT" ]; then
  echo "FAIL: telemetry-ping.sh not found at $PING_SCRIPT" >&2
  exit 1
fi

WORK_DIR=$(mktemp -d)
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
# A port bound and immediately released, so nothing is listening on it. This is
# the "endpoint unreachable" case — a connection refusal, not a timeout.
DEAD_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

PYTHONUNBUFFERED=1 python3 "$HARNESS_DIR/health_server.py" "$PORT" "$WORK_DIR" >"$WORK_DIR/_server.out" 2>&1 &
SERVER_PID=$!

deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ -f "$WORK_DIR/_server_ready" ] && break
  sleep 0.1
done
if [ ! -f "$WORK_DIR/_server_ready" ]; then
  echo "FAIL: health server did not start within 30s" >&2
  cat "$WORK_DIR/_server.out" >&2 || true
  exit 1
fi

LIVE_ENDPOINT="http://127.0.0.1:${PORT}"
DEAD_ENDPOINT="http://127.0.0.1:${DEAD_PORT}"
CHECKPOINT_URL="${LIVE_ENDPOINT}/v1/ping"

PASSED=0
FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL: $1" >&2; FAILED=$((FAILED + 1)); }

# ---------------------------------------------------------------------------
# run_case <label> <health-endpoint> <scenario-json>
#
# Writes the scenario, runs the ping script under a throwaway HOME (so the
# 7-day stamp can never suppress a case), and leaves the captured ping in
# $CASE_PING plus the process's own behaviour in $CASE_RC/$CASE_OUT/$CASE_ERR.
# ---------------------------------------------------------------------------
CASE_PING=""
CASE_RC=0
CASE_OUT=""
CASE_ERR=""
CASE_HEALTH_HITS=0

run_case() {
  local label="$1" health_endpoint="$2" scenario="$3"

  printf '%s' "$scenario" > "$WORK_DIR/_scenario.json"
  : > "$WORK_DIR/_pings.jsonl"
  printf '0' > "$WORK_DIR/_health_hits"

  local sandbox_home
  sandbox_home=$(mktemp -d "$WORK_DIR/home.XXXXXX")

  CASE_OUT=$(
    env -i \
      HOME="$sandbox_home" \
      PATH="$PATH" \
      AXONFLOW_TELEMETRY="" \
      AXONFLOW_CHECKPOINT_URL="$CHECKPOINT_URL" \
      AXONFLOW_HARNESS=1 \
      AXONFLOW_HARNESS_AGENT_ENDPOINT="$health_endpoint" \
      bash "$PING_SCRIPT" 2>"$WORK_DIR/_stderr"
  )
  CASE_RC=$?
  CASE_ERR=$(cat "$WORK_DIR/_stderr" 2>/dev/null)
  CASE_PING=$(head -1 "$WORK_DIR/_pings.jsonl" 2>/dev/null)
  CASE_HEALTH_HITS=$(cat "$WORK_DIR/_health_hits" 2>/dev/null || echo 0)

  # ---- invariants asserted on EVERY case, not only the failure ones -------
  if [ "$CASE_RC" -ne 0 ]; then
    fail "[$label] telemetry-ping.sh exited $CASE_RC (must always be 0)"
  fi
  if [ -n "$CASE_OUT" ]; then
    fail "[$label] wrote to stdout: $CASE_OUT"
  fi
  if [ -n "$CASE_ERR" ]; then
    fail "[$label] wrote to stderr: $CASE_ERR"
  fi
  if [ -z "$CASE_PING" ]; then
    fail "[$label] no heartbeat delivered — enrichment must never suppress the ping"
    return
  fi
  if ! printf '%s' "$CASE_PING" | jq -e . >/dev/null 2>&1; then
    fail "[$label] heartbeat body is not valid JSON: $CASE_PING"
    return
  fi
  # The pre-existing payload must survive intact — a regression here means the
  # new field displaced something the receiver already depends on.
  local missing=""
  local f
  for f in telemetry_type sdk sdk_version os arch runtime_version \
           deployment_mode endpoint_type features instance_id org_id; do
    if ! printf '%s' "$CASE_PING" | jq -e "has(\"$f\")" >/dev/null 2>&1; then
      missing="$missing $f"
    fi
  done
  if [ -n "$missing" ]; then
    fail "[$label] heartbeat lost pre-existing field(s):$missing"
  fi
}

# tier_of prints the license_tier of the captured ping, or the sentinel
# __ABSENT__ when the key is not present at all. The distinction between
# absent, null and "" is the entire point, so it is never collapsed.
tier_of() {
  printf '%s' "$CASE_PING" | jq -r 'if has("license_tier") then (.license_tier | tostring) else "__ABSENT__" end' 2>/dev/null
}

expect_tier() {
  local label="$1" want="$2" got
  got=$(tier_of)
  if [ "$got" = "$want" ]; then
    pass "[$label] license_tier relayed verbatim as $(printf '%q' "$want")"
  else
    fail "[$label] license_tier is $(printf '%q' "$got"), expected $(printf '%q' "$want")"
  fi
}

expect_absent() {
  local label="$1" got
  got=$(tier_of)
  if [ "$got" = "__ABSENT__" ]; then
    pass "[$label] license_tier key absent (not \"unknown\", not null, not \"\")"
  else
    fail "[$label] license_tier is $(printf '%q' "$got"), expected the key to be ABSENT"
  fi
}

health_body() { printf '{"status":200,"body":%s}' "$(jq -Rn --arg b "$1" '$b')"; }

echo "--- Round-trip: every tier the platform can answer with, relayed unchanged ---"

for tier in Community community Evaluation Professional Enterprise Plus EnterprisePlus starting; do
  run_case "tier=$tier" "$LIVE_ENDPOINT" \
    "$(health_body "{\"status\":\"healthy\",\"version\":\"10.3.0\",\"tier\":\"$tier\"}")"
  expect_tier "tier=$tier" "$tier"
done

# A tier this build has never heard of must reach the receiver intact. The
# canonical mapping is the receiver's job; a client that flattened it would
# make every future tier indistinguishable from a broken one.
run_case "unknown-to-build tier" "$LIVE_ENDPOINT" \
  "$(health_body '{"status":"healthy","version":"10.3.0","tier":"SovereignCloud"}')"
expect_tier "unknown-to-build tier" "SovereignCloud"

# Spaces and non-ASCII must survive JSON encoding rather than corrupting the
# payload — jq --arg owns the escaping, and this proves it.
run_case "tier with spaces + unicode" "$LIVE_ENDPOINT" \
  "$(health_body '{"status":"healthy","version":"10.3.0","tier":"Ent erprise ✓"}')"
expect_tier "tier with spaces + unicode" "Ent erprise ✓"

# Boundary: exactly at the 64-character cap is still reported.
TIER64=$(printf 'E%.0s' $(seq 1 64))
run_case "tier at 64-char cap" "$LIVE_ENDPOINT" \
  "$(health_body "{\"status\":\"healthy\",\"version\":\"10.3.0\",\"tier\":\"$TIER64\"}")"
expect_tier "tier at 64-char cap" "$TIER64"

echo ""
echo "--- The three dimensions must disagree, and be reported separately ---"

# license_tier, deployment_mode and endpoint_type describe different things.
# One case where all three differ is worth more than any amount of prose:
# an Enterprise-licensed platform, reached over loopback, classified
# self_hosted. Conflating any pair would collapse two of these values.
run_case "three-way distinction" "$LIVE_ENDPOINT" \
  "$(health_body '{"status":"healthy","version":"10.3.0","tier":"Enterprise"}')"
THREE_LT=$(tier_of)
THREE_DM=$(printf '%s' "$CASE_PING" | jq -r '.deployment_mode')
THREE_ET=$(printf '%s' "$CASE_PING" | jq -r '.endpoint_type')
if [ "$THREE_LT" = "Enterprise" ] && [ "$THREE_DM" = "self_hosted" ] && [ "$THREE_ET" = "localhost" ]; then
  pass "license_tier=Enterprise, deployment_mode=self_hosted, endpoint_type=localhost — three distinct dimensions"
else
  fail "three-way distinction: license_tier=$THREE_LT deployment_mode=$THREE_DM endpoint_type=$THREE_ET (expected Enterprise/self_hosted/localhost)"
fi

# Exactly one /health request. license_tier rides the probe that already
# existed; a second round trip would be a new data collection, not a field.
if [ "$CASE_HEALTH_HITS" = "1" ]; then
  pass "exactly one GET /health per heartbeat (no new network call)"
else
  fail "GET /health hit $CASE_HEALTH_HITS times per heartbeat (expected exactly 1)"
fi

echo ""
echo "--- Fail open: every probe failure omits the key and leaves the ping intact ---"

run_case "endpoint unreachable" "$DEAD_ENDPOINT" "$(health_body '{"tier":"Enterprise"}')"
expect_absent "endpoint unreachable"

# A 5xx body is not an answer. Without --fail, curl hands the error body to jq
# and a tier inside it would be reported as though the platform had said it.
run_case "HTTP 500 carrying a tier" "$LIVE_ENDPOINT" \
  '{"status":500,"body":"{\"status\":\"error\",\"version\":\"10.3.0\",\"tier\":\"Enterprise\"}"}'
expect_absent "HTTP 500 carrying a tier"

run_case "HTTP 404 carrying a tier" "$LIVE_ENDPOINT" \
  '{"status":404,"body":"{\"tier\":\"Enterprise\"}"}'
expect_absent "HTTP 404 carrying a tier"

run_case "malformed JSON body" "$LIVE_ENDPOINT" \
  "$(health_body '{"status":"healthy","version":"10.3.0","tier":"Enterp')"
expect_absent "malformed JSON body"

run_case "empty body" "$LIVE_ENDPOINT" "$(health_body '')"
expect_absent "empty body"

run_case "body is a JSON array" "$LIVE_ENDPOINT" "$(health_body '[{"tier":"Enterprise"}]')"
expect_absent "body is a JSON array"

run_case "body is a bare JSON string" "$LIVE_ENDPOINT" "$(health_body '"Enterprise"')"
expect_absent "body is a bare JSON string"

# The key the whole feature depends on is simply missing — an older platform.
# platform_version must still be reported: the two fields are independent, and
# a plugin that dropped both would lose a signal it already had.
run_case "tier key absent (older platform)" "$LIVE_ENDPOINT" \
  "$(health_body '{"status":"healthy","version":"9.16.0"}')"
expect_absent "tier key absent (older platform)"
MISSING_PV=$(printf '%s' "$CASE_PING" | jq -r '.platform_version')
if [ "$MISSING_PV" = "9.16.0" ]; then
  pass "tier absent does not disturb platform_version (still 9.16.0)"
else
  fail "platform_version is $MISSING_PV, expected 9.16.0 — the two fields must be independent"
fi

# Wrong types. A required string that arrives as another JSON type is invisible
# to any decoder that coerces, so each type is covered explicitly.
run_case "tier: null" "$LIVE_ENDPOINT" "$(health_body '{"version":"10.3.0","tier":null}')"
expect_absent "tier: null"

run_case "tier: number" "$LIVE_ENDPOINT" "$(health_body '{"version":"10.3.0","tier":42}')"
expect_absent "tier: number"

run_case "tier: boolean" "$LIVE_ENDPOINT" "$(health_body '{"version":"10.3.0","tier":true}')"
expect_absent "tier: boolean"

run_case "tier: object" "$LIVE_ENDPOINT" "$(health_body '{"version":"10.3.0","tier":{"name":"Enterprise"}}')"
expect_absent "tier: object"

run_case "tier: array" "$LIVE_ENDPOINT" "$(health_body '{"version":"10.3.0","tier":["Enterprise"]}')"
expect_absent "tier: array"

run_case "tier: empty string" "$LIVE_ENDPOINT" "$(health_body '{"version":"10.3.0","tier":""}')"
expect_absent "tier: empty string"

# Boundary: one character past the cap is dropped whole, never truncated —
# a truncated value would be a tier the platform never reported.
TIER65=$(printf 'E%.0s' $(seq 1 65))
run_case "tier one past the 64-char cap" "$LIVE_ENDPOINT" \
  "$(health_body "{\"version\":\"10.3.0\",\"tier\":\"$TIER65\"}")"
expect_absent "tier one past the 64-char cap"

# A slow platform must cost the heartbeat nothing beyond the probe's own 2s
# budget. The heartbeat still goes out; only the enrichment is missing.
run_case "slow /health (past the 2s probe budget)" "$LIVE_ENDPOINT" \
  '{"status":200,"delay":3.0,"body":"{\"version\":\"10.3.0\",\"tier\":\"Enterprise\"}"}'
expect_absent "slow /health (past the 2s probe budget)"

echo ""
echo "========================================"
echo " license_tier matrix — $(basename "$(dirname "$PING_SCRIPT")")/$(basename "$PING_SCRIPT")"
echo "========================================"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
[ "$FAILED" -eq 0 ]
