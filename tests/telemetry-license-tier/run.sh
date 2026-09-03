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
CASE_STAMPED=0
CASE_REDIRECT_TARGET_HITS=""

# run_case <label> <health-endpoint> <scenario-json> [expect_ping]
#
# expect_ping defaults to 1. Pass 0 for the cases where NOT delivering is the
# correct outcome under test (a redirected checkpoint), so the absence of a
# ping is read as the result rather than as a harness failure.
run_case() {
  local label="$1" health_endpoint="$2" scenario="$3" expect_ping="${4:-1}"

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
  CASE_REDIRECT_TARGET_HITS=$(cat "$WORK_DIR/_redirect_target_hits" 2>/dev/null || printf '')

  # Did the 7-day stamp advance? Found by glob, never by name: the stamp file
  # is named after the plugin and this harness is byte-identical across the
  # three repos that share it.
  CASE_STAMPED=0
  if compgen -G "$sandbox_home/.cache/axonflow/*-telemetry-sent" >/dev/null 2>&1; then
    CASE_STAMPED=1
  fi

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
  if [ "$expect_ping" = "0" ]; then
    # The caller is testing a non-delivery. Everything below asserts on the
    # payload, so there is nothing further to check here.
    return
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
  # platform_version is in this list deliberately: it is read from the same
  # /health body and must ALWAYS be present (JSON null when unknown), so a
  # regression that omitted the key instead is caught here on every case.
  for f in telemetry_type sdk sdk_version platform_version os arch runtime_version \
           deployment_mode endpoint_type features instance_id org_id; do
    if ! printf '%s' "$CASE_PING" | jq -e "has(\"$f\")" >/dev/null 2>&1; then
      missing="$missing $f"
    fi
  done
  if [ -n "$missing" ]; then
    fail "[$label] heartbeat lost pre-existing field(s):$missing"
  fi
}

# Presence is asked of jq directly rather than encoded into a sentinel string.
# A sentinel would be a value the SERVER can also send: a /health answering
# `"tier":"__ABSENT__"` would have made a present key indistinguishable from a
# missing one, in the one helper whose whole job is telling those apart.
field_present() {
  printf '%s' "$CASE_PING" | jq -e --arg k "$1" 'has($k)' >/dev/null 2>&1
}

field_value() {
  printf '%s' "$CASE_PING" | jq -r --arg k "$1" '.[$k] | tostring' 2>/dev/null
}

expect_field() {
  local label="$1" key="$2" want="$3" got
  if ! field_present "$key"; then
    fail "[$label] $key key is ABSENT, expected $(printf '%q' "$want")"
    return
  fi
  got=$(field_value "$key")
  if [ "$got" = "$want" ]; then
    pass "[$label] $key relayed verbatim as $(printf '%q' "$want")"
  else
    fail "[$label] $key is $(printf '%q' "$got"), expected $(printf '%q' "$want")"
  fi
}

expect_field_absent() {
  local label="$1" key="$2"
  if ! field_present "$key"; then
    pass "[$label] $key key absent (not \"unknown\", not null, not \"\")"
  else
    fail "[$label] $key is $(printf '%q' "$(field_value "$key")"), expected the key to be ABSENT"
  fi
}

# license_tier keeps its own names: it has the most call sites below, and the
# wrappers keep this change to the matrix rather than to every existing case.
tier_present() { field_present license_tier; }
tier_value() { field_value license_tier; }
expect_tier() { expect_field "$1" license_tier "$2"; }
expect_absent() { expect_field_absent "$1" license_tier; }

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
THREE_LT=$(tier_value)
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
echo "--- A successful probe must never be able to destroy the heartbeat ---"

# Regression: platform_version used to be spliced into the payload by hand-
# building a JSON string around it. A version CONTAINING a double quote or a
# backslash produced invalid JSON, jq -n failed, and the script exited having
# sent NO ping at all. A probe that answers must never be more dangerous than
# one that does not, so these assert the heartbeat survives and both fields
# arrive intact.
run_case "version containing a double quote" "$LIVE_ENDPOINT" \
  "$(health_body '{"status":"healthy","version":"10.3.0\"evil","tier":"Enterprise"}')"
expect_tier "version containing a double quote" "Enterprise"
QUOTE_PV=$(printf '%s' "$CASE_PING" | jq -r '.platform_version')
if [ "$QUOTE_PV" = '10.3.0"evil' ]; then
  pass "platform_version with an embedded quote survives, escaped by jq"
else
  fail "platform_version is $(printf '%q' "$QUOTE_PV"), expected 10.3.0\"evil"
fi

run_case "version containing a backslash" "$LIVE_ENDPOINT" \
  "$(health_body '{"status":"healthy","version":"10.3.0\\x","tier":"Plus"}')"
expect_tier "version containing a backslash" "Plus"
BS_PV=$(printf '%s' "$CASE_PING" | jq -r '.platform_version')
if [ "$BS_PV" = '10.3.0\x' ]; then
  pass "platform_version with an embedded backslash survives, escaped by jq"
else
  fail "platform_version is $(printf '%q' "$BS_PV"), expected 10.3.0\\x"
fi

# The unknown case must still serialise as JSON null, not the string "null" and
# not an omitted key - the receiver's existing contract for this field.
run_case "version absent keeps platform_version JSON null" "$LIVE_ENDPOINT" \
  "$(health_body '{"status":"healthy","tier":"Enterprise"}')"
if printf '%s' "$CASE_PING" | jq -e 'has("platform_version") and .platform_version == null' >/dev/null 2>&1; then
  pass "platform_version is JSON null when unknown (key present, value null)"
else
  fail "platform_version is $(printf '%s' "$CASE_PING" | jq -c '.platform_version // "__ABSENT__"'), expected JSON null"
fi

echo ""
echo "--- edition and platform_deployment_mode relay on the same terms ---"

# Round-trip. These are the two members enterprise#3662 adds to /health; the
# values are relayed verbatim, exactly as license_tier is.
for ed in community enterprise Enterprise starting SomethingThisBuildNeverHeardOf; do
  run_case "edition=$ed" "$LIVE_ENDPOINT" \
    "$(health_body "{\"version\":\"10.4.0\",\"tier\":\"Enterprise\",\"edition\":\"$ed\"}")"
  expect_field "edition=$ed" edition "$ed"
done

for pdm in self_hosted community_saas kubernetes docker_compose unknown; do
  run_case "platform_deployment_mode=$pdm" "$LIVE_ENDPOINT" \
    "$(health_body "{\"version\":\"10.4.0\",\"tier\":\"Enterprise\",\"deployment_mode\":\"$pdm\"}")"
  expect_field "platform_deployment_mode=$pdm" platform_deployment_mode "$pdm"
done

# THE case that makes the relay meaningful rather than merely present. The
# platform reports community_saas about ITSELF while this plugin classifies the
# endpoint it was pointed at as self_hosted. A fixture where the two agree
# cannot tell a correct relay from one that wrote the platform's answer over
# the plugin's own field - and that mistake corrupts every existing
# deployment-mode figure rather than losing a dimension.
run_case "platform mode differs from local classification" "$LIVE_ENDPOINT" \
  "$(health_body '{"version":"10.4.0","tier":"Enterprise","edition":"enterprise","deployment_mode":"community_saas"}')"
expect_field "platform mode differs" platform_deployment_mode "community_saas"
expect_field "platform mode differs" deployment_mode "self_hosted"
if [ "$(field_value deployment_mode)" != "$(field_value platform_deployment_mode)" ]; then
  pass "deployment_mode (self_hosted, local) and platform_deployment_mode (community_saas, reported) stayed distinct"
else
  fail "the platform's deployment mode was written over this plugin's own classification"
fi

# All four relays ride ONE probe. A second request would make these new data
# collection rather than new fields on a probe that already happened.
if [ "$CASE_HEALTH_HITS" = "1" ]; then
  pass "exactly one GET /health for all four relayed fields"
else
  fail "GET /health hit $CASE_HEALTH_HITS times (expected exactly 1)"
fi

echo ""
echo "--- Fail open applies to the new fields identically ---"

# An older platform - every released platform today, in fact - simply has no
# such members. Absent, never defaulted.
run_case "edition + mode absent (platform predates #3662)" "$LIVE_ENDPOINT" \
  "$(health_body '{"status":"healthy","version":"10.3.0","tier":"Enterprise"}')"
expect_field_absent "edition absent" edition
expect_field_absent "mode absent" platform_deployment_mode
expect_tier "tier still relayed alongside" "Enterprise"

for bad in 'null' '42' 'true' '{"a":1}' '["x"]' '""'; do
  run_case "edition: $bad" "$LIVE_ENDPOINT" \
    "$(health_body "{\"version\":\"10.4.0\",\"edition\":$bad}")"
  expect_field_absent "edition: $bad" edition
done

for bad in 'null' '42' 'true' '{"a":1}' '["x"]' '""'; do
  run_case "deployment_mode: $bad" "$LIVE_ENDPOINT" \
    "$(health_body "{\"version\":\"10.4.0\",\"deployment_mode\":$bad}")"
  expect_field_absent "deployment_mode: $bad" platform_deployment_mode
done

# Over the cap: dropped whole, never truncated, and never at the cost of the
# fields that were fine.
ED65=$(printf 'E%.0s' $(seq 1 65))
run_case "edition one past the 64-char cap" "$LIVE_ENDPOINT" \
  "$(health_body "{\"version\":\"10.4.0\",\"tier\":\"Enterprise\",\"edition\":\"$ED65\"}")"
expect_field_absent "edition one past the cap" edition
expect_tier "an over-long edition does not cost the tier" "Enterprise"

ED64=$(printf 'E%.0s' $(seq 1 64))
run_case "edition at the 64-char cap" "$LIVE_ENDPOINT" \
  "$(health_body "{\"version\":\"10.4.0\",\"edition\":\"$ED64\"}")"
expect_field "edition at the cap" edition "$ED64"

# A 10 KB value is the shape that matters: uncapped, it would push the ping
# past the receiver's 64 KiB body limit and cost every other dimension.
BIG=$(printf 'T%.0s' $(seq 1 10240))
run_case "10 KB deployment_mode" "$LIVE_ENDPOINT" \
  "$(health_body "{\"version\":\"10.4.0\",\"tier\":\"Enterprise\",\"deployment_mode\":\"$BIG\"}")"
expect_field_absent "10 KB deployment_mode" platform_deployment_mode
expect_tier "a 10 KB value does not cost the tier" "Enterprise"
PING_BYTES=${#CASE_PING}
if [ "$PING_BYTES" -lt 65536 ]; then
  pass "ping stayed at $PING_BYTES bytes, inside the receiver's 64 KiB limit"
else
  fail "ping is $PING_BYTES bytes, at or over the receiver's 64 KiB limit"
fi

# Hostile but VALID values. The dangerous case is a probe that SUCCEEDS: these
# must be escaped by jq as values, not spliced into the payload.
run_case "edition containing a quote and a backslash" "$LIVE_ENDPOINT" \
  "$(health_body '{"version":"10.4.0","edition":"ent\"erp\\rise","tier":"Plus"}')"
expect_field "edition with quote+backslash" edition 'ent"erp\rise'
expect_tier "hostile edition does not cost the tier" "Plus"

run_case "deployment_mode containing a newline" "$LIVE_ENDPOINT" \
  "$(health_body '{"version":"10.4.0","deployment_mode":"self\nhosted","tier":"Plus"}')"
expect_field "mode with newline" platform_deployment_mode "$(printf 'self\nhosted')"

echo ""
echo "--- Redirects are not followed, on either leg ---"

# A /health that redirects. curl does not follow (no -L), so nothing is
# learned - and, crucially, the redirect TARGET is never contacted. The target
# serves values a relay would happily forward, so finding them on the wire
# would mean the probe read from a host the caller never configured.
# THE case a Content-Length-0 redirect fixture could not express: the 302
# CARRIES a full /health document. A probe gated only on "not an error" parses
# it and relays every value from a response the platform never meant as an
# answer. `--fail` alone rejects >= 400 only, so this passed before the status
# was checked explicitly.
run_case "/health 302 CARRYING a health body" "$LIVE_ENDPOINT" \
  "$(printf '{"status":302,"location":"%s/elsewhere","body":"{\\"version\\":\\"6.6.6\\",\\"tier\\":\\"LeakedFromRedirect\\",\\"edition\\":\\"leaked\\",\\"deployment_mode\\":\\"leaked\\"}"}' "$LIVE_ENDPOINT")"
expect_absent "/health 302 carrying a body"
expect_field_absent "/health 302 carrying a body" edition
expect_field_absent "/health 302 carrying a body" platform_deployment_mode
REDIR_PV=$(printf '%s' "$CASE_PING" | jq -r '.platform_version')
if [ "$REDIR_PV" = "null" ]; then
  pass "a 302's body is not mined for platform_version either"
else
  fail "platform_version is $REDIR_PV — read from a 302's body"
fi

run_case "/health redirects elsewhere" "$LIVE_ENDPOINT" \
  "$(printf '{"status":302,"location":"%s/elsewhere","body":""}' "$LIVE_ENDPOINT")"
expect_absent "/health redirects elsewhere"
expect_field_absent "/health redirects elsewhere" edition
expect_field_absent "/health redirects elsewhere" platform_deployment_mode
if [ -z "$CASE_REDIRECT_TARGET_HITS" ]; then
  pass "the redirect target was never contacted"
else
  fail "the probe followed a redirect: $CASE_REDIRECT_TARGET_HITS"
fi

# THE stamp case. A checkpoint URL answering 302 is not a delivery: curl does
# not follow it, so the receiver never sees the payload. `--fail` alone would
# exit 0 here (it fails on >= 400 only) and the 7-day stamp would advance on a
# ping that was never sent, taking this machine dark for a week.
run_case "checkpoint POST redirects" "$LIVE_ENDPOINT" \
  "$(printf '{"status":200,"body":"{\\"version\\":\\"10.4.0\\",\\"tier\\":\\"Enterprise\\"}","ping_status":302,"ping_location":"%s/sink"}' "$LIVE_ENDPOINT")" 0
if [ -z "$CASE_PING" ]; then
  pass "a redirected checkpoint POST delivered no ping (as expected)"
else
  fail "a ping was recorded despite the redirect: $CASE_PING"
fi
if [ "$CASE_STAMPED" = "0" ]; then
  pass "the 7-day stamp did NOT advance on a redirected checkpoint POST"
else
  fail "the stamp advanced on a ping the receiver never processed — this machine would go dark for 7 days"
fi
if [ -z "$CASE_REDIRECT_TARGET_HITS" ]; then
  pass "the checkpoint redirect target was never contacted"
else
  fail "the POST followed a redirect: $CASE_REDIRECT_TARGET_HITS"
fi

# A checkpoint that REJECTS outright. Distinct from the redirect case: this is
# the >= 400 half of the guard, which moved out of `--fail` and into the `2??`
# pattern when delivery became a status check. A pattern can narrow silently in
# a way a flag cannot, so the boundary is tested from BOTH sides.
run_case "checkpoint POST rejected 500" "$LIVE_ENDPOINT" \
  "$(health_body '{"version":"10.4.0","tier":"Enterprise"}' | jq -c '. + {ping_status: 500}')" 0
if [ "$CASE_STAMPED" = "0" ]; then
  pass "a 500 from the checkpoint does NOT advance the stamp"
else
  fail "the stamp advanced on a rejected ping"
fi

run_case "checkpoint POST rejected 404" "$LIVE_ENDPOINT" \
  "$(health_body '{"version":"10.4.0","tier":"Enterprise"}' | jq -c '. + {ping_status: 404}')" 0
if [ "$CASE_STAMPED" = "0" ]; then
  pass "a 404 from the checkpoint does NOT advance the stamp"
else
  fail "the stamp advanced on a rejected ping"
fi

# A NUL cannot survive a shell variable: command substitution drops it and
# warns on stderr, and this script must never write to stderr. Dropped whole.
run_case "tier containing a NUL byte" "$LIVE_ENDPOINT" \
  "$(health_body '{"version":"10.4.0","tier":"Ent\u0000erprise","edition":"community"}')"
expect_absent "tier containing a NUL byte"
expect_field "a NUL in one value does not cost another" edition "community"

# The cap is BYTES, not characters. 32 three-byte runes are 96 bytes: under a
# character cap of 64, over a byte cap of 64. README says bytes.
MULTIBYTE=$(printf '\u4e2d%.0s' $(seq 1 32))
run_case "edition of 32 three-byte runes (96 bytes)" "$LIVE_ENDPOINT" \
  "$(health_body "{\"version\":\"10.4.0\",\"tier\":\"Enterprise\",\"edition\":\"$MULTIBYTE\"}")"
expect_field_absent "96-byte edition" edition
expect_tier "an over-byte-cap edition does not cost the tier" "Enterprise"

# ...and one that fits in bytes still round-trips.
MULTIBYTE_OK=$(printf '\u4e2d%.0s' $(seq 1 21))
run_case "edition of 21 three-byte runes (63 bytes)" "$LIVE_ENDPOINT" \
  "$(health_body "{\"version\":\"10.4.0\",\"edition\":\"$MULTIBYTE_OK\"}")"
expect_field "63-byte edition" edition "$MULTIBYTE_OK"

# The positive control for the two above: an ordinary 200 DOES stamp. Without
# it, a script that never stamped at all would pass both assertions.
run_case "ordinary delivery stamps" "$LIVE_ENDPOINT" \
  "$(health_body '{"version":"10.4.0","tier":"Enterprise"}')"
if [ "$CASE_STAMPED" = "1" ]; then
  pass "a delivered ping DOES advance the stamp (control)"
else
  fail "the stamp did not advance on a successful delivery — the redirect assertions above prove nothing"
fi

echo ""
echo "========================================"
echo " relay matrix — $(basename "$(dirname "$PING_SCRIPT")")/$(basename "$PING_SCRIPT")"
echo "========================================"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
[ "$FAILED" -eq 0 ]
