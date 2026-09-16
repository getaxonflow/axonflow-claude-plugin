#!/usr/bin/env bash
# Unit tests for scripts/upgrade-prompt.sh — V1 Plugin Pro envelope handling.
#
# Exercises every branch of axonflow_handle_envelope_response +
# axonflow_throttle_active using captured envelope shapes that match the
# locked wire contract from
# axonflow-enterprise/platform/agent/community_saas_ratelimit_response.go.
#
# Each fixture body is a verbatim copy of what the agent emits — generated
# from `runtime-e2e/v1_pro_envelope_surface/EVIDENCE/<utc-ts>/envelope_body.json`
# (real wire) and the `community_saas_ratelimit_response_test.go` golden
# files. Edits to the locked envelope shape MUST flow through both that Go
# test and these fixtures.
#
# These run on every PR (`./tests/test-hooks.sh` companion). The runtime-e2e
# harness runs against try.getaxonflow.com but requires AWS access for the
# DB-seed path, so this unit suite is the always-on safety net.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$PLUGIN_DIR/scripts/upgrade-prompt.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: $HELPER not found"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  # A here-string, not a pipe: under pipefail `echo | grep -q` can read a
  # match as a miss (grep exits at the first match and echo takes SIGPIPE).
  if grep -qF -e "$needle" <<<"$haystack"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to find '$needle' in:)"
    echo "$haystack" | head -5 | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! grep -qF -e "$needle" <<<"$haystack"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected NOT to find '$needle' in:)"
    echo "$haystack" | head -5 | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

# Each test runs in a subshell that emits "PASS_INC=N FAIL_INC=N" on its
# last line; the parent reads that line and increments the running totals.
# Subshell isolation is required because:
#   - upgrade-prompt.sh's _AXONFLOW_UPGRADE_PROMPT_LOADED guard would
#     otherwise short-circuit re-sourcing (functions defined once, never
#     re-bound to a fresh XDG_CACHE_HOME).
#   - Once-per-day stamps live in $XDG_CACHE_HOME and bleed across tests
#     unless each test gets a fresh cache.
run_test() {
  local name="$1"
  shift
  echo
  echo "=== $name ==="
  local out
  out=$(
    (
      PASS=0
      FAIL=0
      "$@"
      echo "TEST_RESULT_PASS=$PASS"
      echo "TEST_RESULT_FAIL=$FAIL"
    )
  )
  # Print everything except the magic trailers so the human sees the
  # PASS/FAIL lines in real-time order.
  echo "$out" | grep -v '^TEST_RESULT_'
  local sub_pass sub_fail
  sub_pass=$(echo "$out" | awk -F= '/^TEST_RESULT_PASS=/{print $2}')
  sub_fail=$(echo "$out" | awk -F= '/^TEST_RESULT_FAIL=/{print $2}')
  PASS=$((PASS + ${sub_pass:-0}))
  FAIL=$((FAIL + ${sub_fail:-0}))
}

mk_tmp_cache() {
  local d
  d=$(mktemp -d -t axonflow-upprompt.XXXXXX)
  echo "$d"
}

mk_body_429_daily_quota() {
  cat <<'EOF'
{
  "error": "Daily request limit reached. Resets at midnight UTC.",
  "limit_type": "daily_quota",
  "tier": "Free",
  "limit": 200,
  "remaining": 0,
  "window": "daily_utc",
  "resets_at": "2099-12-31T23:59:59Z",
  "upgrade": {
    "tier": "Pro",
    "wording": "Daily limit reached on Free tier (200 events). Pro raises this to 2,000/day. Resets at midnight UTC.",
    "compare_url": "https://getaxonflow.com/pricing/",
    "buy_url": "https://buy.stripe.com/bJe28qbztcdVchjdkw8k800"
  }
}
EOF
}

mk_body_403_active_policies() {
  cat <<'EOF'
{
  "error": "Free tier supports 2 active custom policies. Delete one to make room, or Pro removes the cap.",
  "limit_type": "active_policies",
  "tier": "Free",
  "limit": 2,
  "remaining": 0,
  "upgrade": {
    "tier": "Pro",
    "wording": "Free tier supports 2 active custom policies. Delete one to make room, or Pro removes the cap.",
    "compare_url": "https://getaxonflow.com/pricing/",
    "buy_url": "https://buy.stripe.com/bJe28qbztcdVchjdkw8k800"
  }
}
EOF
}

# JSON-RPC wrapped envelope (returned by /api/v1/mcp-server tools/call when
# enforceMCPToolGate fires writeMCPGateError — see mcp_v1_pro_tools.go).
mk_body_jsonrpc_wrapped_envelope() {
  cat <<'EOF'
{
  "jsonrpc": "2.0",
  "id": "call-1",
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\n  \"error\": \"Free tier supports 2 active custom policies. Delete one to make room, or Pro removes the cap.\",\n  \"limit_type\": \"active_policies\",\n  \"tier\": \"Free\",\n  \"limit\": 2,\n  \"remaining\": 0,\n  \"upgrade\": {\n    \"tier\": \"Pro\",\n    \"wording\": \"Free tier supports 2 active custom policies. Delete one to make room, or Pro removes the cap.\",\n    \"compare_url\": \"https://getaxonflow.com/pricing/\",\n    \"buy_url\": \"https://buy.stripe.com/bJe28qbztcdVchjdkw8k800\"\n  }\n}"
      }
    ],
    "isError": true
  }
}
EOF
}

mk_headers_429_with_retry_after() {
  cat <<'EOF'
HTTP/2 429
content-type: application/json
x-axonflow-tier-limit: daily_quota
x-axonflow-upgrade-url: https://getaxonflow.com/pricing/
retry-after: 3600
date: Thu, 07 May 2026 00:25:10 GMT
EOF
}

mk_headers_403_no_retry_after() {
  cat <<'EOF'
HTTP/2 403
content-type: application/json
x-axonflow-tier-limit: active_policies
x-axonflow-upgrade-url: https://getaxonflow.com/pricing/
date: Thu, 07 May 2026 00:25:10 GMT
EOF
}

mk_body_legacy_429_no_envelope() {
  # Legacy / older self-hosted stacks that haven't been updated to the
  # V1 envelope shape — body is a bare error string.
  cat <<'EOF'
{"error": "Rate limit exceeded (20 req/min). Try again shortly."}
EOF
}

# ---------------------------------------------------------------------------
# Test 1: 429 daily-quota envelope is detected, wording surfaced, throttle
# stamped from resets_at.
# ---------------------------------------------------------------------------
test_429_daily_quota() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr_out
  body=$(mktemp); mk_body_429_daily_quota >"$body"
  headers=$(mktemp); mk_headers_429_with_retry_after >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "429" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc == 0 (envelope detected)" "0" "$rc"
  assert_contains "stderr carries locked wording" "$(cat "$stderr_out")" "Pro raises this to 2,000/day"
  assert_contains "stderr carries Pro upgrade pointer" "$(cat "$stderr_out")" "https://buy.stripe.com/bJe28qbztcdVchjdkw8k800"

  # Throttle file stamped, deadline in the future.
  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file exists" "yes" "$([ -f "$tf" ] && echo yes || echo no)"
  if [ -f "$tf" ]; then
    local epoch; epoch=$(awk 'NR==1 {print $1}' "$tf")
    local now; now=$(date -u +%s)
    if [ -n "$epoch" ] && [ "$epoch" -gt "$now" ]; then
      assert_eq "deadline in the future" "yes" "yes"
    else
      assert_eq "deadline in the future" "yes" "no (epoch=$epoch now=$now)"
    fi
  fi

  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 2: 403 active_policies envelope (no resets_at, no Retry-After) still
# stamps a short throttle deadline so the next call backs off briefly.
# ---------------------------------------------------------------------------
test_403_active_policies() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr_out
  body=$(mktemp); mk_body_403_active_policies >"$body"
  headers=$(mktemp); mk_headers_403_no_retry_after >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "403" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc == 0 (envelope detected)" "0" "$rc"
  assert_contains "stderr carries active_policies wording" "$(cat "$stderr_out")" "Free tier supports 2 active custom policies"

  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file exists despite no resets_at" "yes" "$([ -f "$tf" ] && echo yes || echo no)"

  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 3: JSON-RPC wrapped envelope (the shape returned on the MCP path
# by writeMCPGateError) is parsed via the dual-shape branch.
# ---------------------------------------------------------------------------
test_jsonrpc_wrapped_envelope() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr_out
  body=$(mktemp); mk_body_jsonrpc_wrapped_envelope >"$body"
  # MCP path returns 200 OK with the gate result inside JSON-RPC; the
  # helper still treats it as envelope-bearing because limit_type is
  # present in the wrapped text. Documented behaviour.
  headers=$(mktemp); mk_headers_403_no_retry_after >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "403" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc == 0 (wrapped envelope detected)" "0" "$rc"
  assert_contains "stderr carries wrapped wording" "$(cat "$stderr_out")" "Free tier supports 2 active custom policies"

  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 4: legacy 429 (no envelope, just bare error) — helper returns
# non-zero so caller's existing fall-open path runs unchanged. Critical
# guard: older self-hosted stacks must NOT see new behaviour.
# ---------------------------------------------------------------------------
test_legacy_429_no_envelope_preserves_behaviour() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr_out
  body=$(mktemp); mk_body_legacy_429_no_envelope >"$body"
  headers=$(mktemp); echo "" >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "429" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc != 0 (no envelope; caller falls through)" "1" "$rc"

  # Throttle file MUST NOT be stamped — caller's normal path runs.
  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file NOT stamped on legacy 429" "no" "$([ -f "$tf" ] && echo yes || echo no)"

  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 5: non-429/403 status (e.g. 200) is rejected immediately — even
# if the body were envelope-shaped, we don't fire on success codes.
# ---------------------------------------------------------------------------
test_non_4xx_status_ignored() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers
  body=$(mktemp); mk_body_429_daily_quota >"$body"
  headers=$(mktemp); mk_headers_429_with_retry_after >"$headers"

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "200" "$body" "$headers" 2>/dev/null
  local rc=$?
  assert_eq "rc != 0 for HTTP 200" "1" "$rc"

  axonflow_handle_envelope_response "500" "$body" "$headers" 2>/dev/null
  rc=$?
  assert_eq "rc != 0 for HTTP 500" "1" "$rc"

  rm -f "$body" "$headers"
}

# ---------------------------------------------------------------------------
# Test 6: once-per-UTC-day stamp suppresses the wording on the second
# invocation against the same envelope.
# ---------------------------------------------------------------------------
test_once_per_day_stamp() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr1 stderr2
  body=$(mktemp); mk_body_429_daily_quota >"$body"
  headers=$(mktemp); mk_headers_429_with_retry_after >"$headers"
  stderr1=$(mktemp)
  stderr2=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "429" "$body" "$headers" 2>"$stderr1"
  axonflow_handle_envelope_response "429" "$body" "$headers" 2>"$stderr2"

  assert_contains "first invocation prints wording" "$(cat "$stderr1")" "Pro raises this to 2,000/day"
  assert_not_contains "second invocation suppresses wording (once-per-day)" \
    "$(cat "$stderr2")" "Pro raises this to 2,000/day"

  rm -f "$body" "$headers" "$stderr1" "$stderr2"
}

# ---------------------------------------------------------------------------
# Test 7: axonflow_throttle_active reflects the stamped deadline.
#   - no stamp → returns 1 (no throttle)
#   - future-epoch stamp → returns 0 (active)
#   - past-epoch stamp → returns 1 + clears the file
# ---------------------------------------------------------------------------
test_throttle_active_states() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  # shellcheck disable=SC1090
  . "$HELPER"

  # Case A: no file
  axonflow_throttle_active
  assert_eq "no stamp → throttle inactive" "1" "$?"

  # Case B: future epoch
  mkdir -p "$cache/axonflow"
  echo "9999999999 daily_quota" >"$cache/axonflow/throttle-until"
  axonflow_throttle_active
  assert_eq "future epoch → throttle active" "0" "$?"

  # Case C: past epoch — should clear the file
  echo "1 daily_quota" >"$cache/axonflow/throttle-until"
  axonflow_throttle_active
  assert_eq "past epoch → throttle inactive" "1" "$?"
  assert_eq "past-epoch stamp file cleared" "no" \
    "$([ -f "$cache/axonflow/throttle-until" ] && echo yes || echo no)"
}

# ---------------------------------------------------------------------------
# Test 8: helper writes nothing to stdout (stdout is reserved for the
# Claude Code hook protocol; any byte breaks the parser).
# ---------------------------------------------------------------------------
test_no_stdout_bytes() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stdout_out
  body=$(mktemp); mk_body_429_daily_quota >"$body"
  headers=$(mktemp); mk_headers_429_with_retry_after >"$headers"
  stdout_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "429" "$body" "$headers" >"$stdout_out" 2>/dev/null
  local size; size=$(wc -c <"$stdout_out" | tr -d ' ')
  assert_eq "stdout is empty" "0" "$size"

  rm -f "$body" "$headers" "$stdout_out"
}

# ---------------------------------------------------------------------------
# Test 9: HTTP 401 → axonflow_handle_auth_failure stamps a 5-minute throttle
# with limit_type=auth_failure + emits the credential-refresh nudge to
# stderr. Regression guard for axonflow-enterprise#2275 (auth-storm retry
# loop: 716 × 401 in 24h from a single source IP because 401 wasn't
# detected by the envelope handler).
# ---------------------------------------------------------------------------
test_401_auth_failure_stamps_throttle() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"
  # Ensure the test doesn't inherit a custom cooldown from the host env.
  unset AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS

  local body headers stderr_out
  body=$(mktemp); echo '{"error":"invalid credentials"}' >"$body"
  headers=$(mktemp); printf 'HTTP/2 401\r\ncontent-type: application/json\r\n' >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  local now_before; now_before=$(date -u +%s)
  axonflow_handle_auth_failure "401" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc == 0 (401 detected)" "0" "$rc"
  assert_contains "stderr names HTTP 401" "$(cat "$stderr_out")" "Authentication failed (HTTP 401)"
  # The 401 now BLOCKS governed calls for the cooldown (it used to let them
  # run: "Tool governance is paused for 5 minutes").
  assert_contains "stderr says governed calls are blocked" "$(cat "$stderr_out")" "Governed tool calls are blocked"
  assert_contains "stderr names the cooldown's seconds" "$(cat "$stderr_out")" "not asked again for 300 seconds"
  assert_contains "stderr names the stamp file to delete" "$(cat "$stderr_out")" "$cache/axonflow/throttle-until is deleted"
  assert_not_contains "stderr no longer says governance is paused" "$(cat "$stderr_out")" "paused"
  assert_contains "stderr links to dashboard for credential refresh" \
    "$(cat "$stderr_out")" "https://getaxonflow.com/dashboard"

  # Throttle file written with auth_failure limit_type and deadline ~ now + 300.
  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file exists" "yes" "$([ -f "$tf" ] && echo yes || echo no)"
  if [ -f "$tf" ]; then
    local epoch limit
    epoch=$(awk 'NR==1 {print $1}' "$tf")
    limit=$(awk 'NR==1 {print $2}' "$tf")
    assert_eq "limit_type stamped as auth_failure" "auth_failure" "$limit"
    # Deadline must sit in the (now+290, now+310) window — allow ±10s wall-clock
    # slack so this assertion isn't flaky on a busy CI runner without losing
    # the mutation-test value (a cooldown of 0 collapses to 'now' which is
    # well outside the lower bound and trips the assertion).
    local now_after; now_after=$(date -u +%s)
    local floor=$((now_before + 290))
    local ceil=$((now_after + 310))
    if [ -n "$epoch" ] && [ "$epoch" -ge "$floor" ] && [ "$epoch" -le "$ceil" ]; then
      assert_eq "deadline ~ now + 300s" "yes" "yes"
    else
      assert_eq "deadline ~ now + 300s" "yes" \
        "no (epoch=$epoch, floor=$floor, ceil=$ceil)"
    fi
  fi

  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 10: non-401 statuses (403, 429, 500, network failure as empty string)
# are NOT handled by axonflow_handle_auth_failure. Critical guard so the
# 401 path doesn't shadow the existing 429/403 envelope path or stamp a
# throttle on transient 5xx (which would unnecessarily silence governance).
# ---------------------------------------------------------------------------
test_non_401_statuses_not_handled() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers
  body=$(mktemp); echo '{}' >"$body"
  headers=$(mktemp); echo "" >"$headers"

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_auth_failure "403" "$body" "$headers" 2>/dev/null
  assert_eq "rc != 0 for HTTP 403 (envelope handler owns this)" "1" "$?"
  axonflow_handle_auth_failure "429" "$body" "$headers" 2>/dev/null
  assert_eq "rc != 0 for HTTP 429 (envelope handler owns this)" "1" "$?"
  axonflow_handle_auth_failure "500" "$body" "$headers" 2>/dev/null
  assert_eq "rc != 0 for HTTP 500 (transient, fall through)" "1" "$?"
  axonflow_handle_auth_failure "200" "$body" "$headers" 2>/dev/null
  assert_eq "rc != 0 for HTTP 200 (success, fall through)" "1" "$?"
  axonflow_handle_auth_failure "" "$body" "$headers" 2>/dev/null
  assert_eq "rc != 0 for empty status (curl network failure)" "1" "$?"

  # Throttle file MUST NOT exist after any of the above.
  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file NOT stamped on non-401" "no" \
    "$([ -f "$tf" ] && echo yes || echo no)"

  rm -f "$body" "$headers"
}

# ---------------------------------------------------------------------------
# Test 11: second consecutive 401 within the same UTC day suppresses the
# stderr prompt (one-time-per-day stamp), but still re-stamps the throttle
# deadline. Matches the envelope-prompt behaviour.
# ---------------------------------------------------------------------------
test_401_prompt_once_per_day() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"
  unset AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS

  local body headers stderr1 stderr2
  body=$(mktemp); echo '{}' >"$body"
  headers=$(mktemp); echo "" >"$headers"
  stderr1=$(mktemp)
  stderr2=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_auth_failure "401" "$body" "$headers" 2>"$stderr1"
  axonflow_handle_auth_failure "401" "$body" "$headers" 2>"$stderr2"

  assert_contains "first 401 prints credential-refresh nudge" \
    "$(cat "$stderr1")" "Authentication failed (HTTP 401)"
  assert_not_contains "second 401 suppresses nudge (once-per-day stamp)" \
    "$(cat "$stderr2")" "Authentication failed (HTTP 401)"

  # Throttle file still present (re-stamped on second 401).
  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file still present after second 401" "yes" \
    "$([ -f "$tf" ] && echo yes || echo no)"

  rm -f "$body" "$headers" "$stderr1" "$stderr2"
}

# ---------------------------------------------------------------------------
# Test 12: stdout is empty under the 401 path — stdout is the Claude Code
# hook protocol surface and any byte breaks the parser.
# ---------------------------------------------------------------------------
test_401_no_stdout_bytes() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stdout_out
  body=$(mktemp); echo '{}' >"$body"
  headers=$(mktemp); echo "" >"$headers"
  stdout_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_auth_failure "401" "$body" "$headers" >"$stdout_out" 2>/dev/null
  local size; size=$(wc -c <"$stdout_out" | tr -d ' ')
  assert_eq "stdout is empty on 401 path" "0" "$size"

  rm -f "$body" "$headers" "$stdout_out"
}

# ---------------------------------------------------------------------------
# Test 13: separate-stamp regression guard (v1.5.2 follow-up to v1.5.1).
#
# Pre-1.5.2 the 401 nudge piggy-backed on `_AXONFLOW_PROMPT_STAMP`, which
# meant a tier-limit upgrade-prompt earlier in the day would silently
# suppress a later credential-refresh nudge — closing the same auth-storm
# loop axonflow-enterprise#2275 was meant to prevent (the operator never
# sees the "refresh your credentials" message because the envelope handler
# had stamped the shared file an hour ago for a 429).
#
# Regression scenario:
#   1. Pre-stamp `upgrade-prompt-last-shown` with today's UTC date
#      (simulates an earlier envelope nudge or any prior 401 nudge under
#      the old design).
#   2. Call `axonflow_handle_auth_failure 401 ...` (fresh handler invocation
#      that hasn't yet stamped the auth-failure file).
#   3. Assert the nudge appears on stderr — the auth-prompt stamp is a
#      separate file, so the shared envelope stamp must not gate it.
#
# Mutation proof: revert _AXONFLOW_AUTH_PROMPT_STAMP back to the shared
# _AXONFLOW_PROMPT_STAMP path AND `_axonflow_should_show_auth_prompt_today`
# back to `_axonflow_should_show_prompt_today` — both halves of the fix
# are needed and this test fails (stderr is empty) if either is reverted.
# Verified manually 2026-05-20.
# ---------------------------------------------------------------------------
test_401_separate_stamp_not_suppressed_by_envelope_stamp() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"
  unset AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS

  # Pre-stamp the envelope's once-per-day file with today's UTC date,
  # simulating an earlier upgrade-prompt nudge (or any prior caller of
  # `_axonflow_should_show_prompt_today`).
  mkdir -p "$cache/axonflow"
  local today; today=$(date -u +%Y-%m-%d)
  echo "$today" >"$cache/axonflow/upgrade-prompt-last-shown"

  local body headers stderr_out
  body=$(mktemp); echo '{"error":"invalid credentials"}' >"$body"
  headers=$(mktemp); printf 'HTTP/2 401\r\n' >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_auth_failure "401" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc == 0 (401 still detected)" "0" "$rc"
  # Critical assertion: the credential-refresh nudge MUST fire even though
  # the envelope's stamp file already carries today's date.
  assert_contains "401 nudge fires despite pre-stamped upgrade-prompt file" \
    "$(cat "$stderr_out")" "Authentication failed (HTTP 401)"
  assert_contains "dashboard link present" \
    "$(cat "$stderr_out")" "https://getaxonflow.com/dashboard"

  # The auth-failure stamp is now its own file — verify the new file
  # landed (and the envelope file is unchanged from the pre-stamp).
  assert_eq "separate auth-prompt stamp file written" "yes" \
    "$([ -f "$cache/axonflow/auth-failure-prompt-last-shown" ] && echo yes || echo no)"
  assert_eq "envelope stamp file untouched by auth-failure path" "$today" \
    "$(awk 'NR==1 {print $1}' "$cache/axonflow/upgrade-prompt-last-shown")"

  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 14: inverse cross-stamp isolation — pre-stamping the auth-failure
# file does NOT suppress an envelope-handler nudge. Belt-and-suspenders
# guard so a future refactor doesn't accidentally re-share the stamp in
# the other direction.
# ---------------------------------------------------------------------------
test_envelope_not_suppressed_by_auth_stamp() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  # Pre-stamp the auth-failure file with today's UTC date.
  mkdir -p "$cache/axonflow"
  local today; today=$(date -u +%Y-%m-%d)
  echo "$today" >"$cache/axonflow/auth-failure-prompt-last-shown"

  local body headers stderr_out
  body=$(mktemp); mk_body_429_daily_quota >"$body"
  headers=$(mktemp); mk_headers_429_with_retry_after >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "429" "$body" "$headers" 2>"$stderr_out"
  assert_contains "envelope wording fires despite pre-stamped auth-failure file" \
    "$(cat "$stderr_out")" "Pro raises this to 2,000/day"

  rm -f "$body" "$headers" "$stderr_out"
}


# ---------------------------------------------------------------------------
# Test 15: the stamp rules (axonflow_governed_stamp), with the clock pinned.
# axonflow-enterprise#4249 comment 5684124176: only a request-rate limit
# (daily_quota, per_minute) gates, for at most 300 s after the stamp was
# written; a stamp written more than 60 s in the future is past the cap; a
# feature or object-count limit gates nothing; auth_failure gates for its
# configured length from when its file was written. A stamp that does not gate is left on disk.
# ---------------------------------------------------------------------------
test_governed_stamp_rules() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"
  # shellcheck disable=SC1090
  . "$HELPER"

  local now tf out rc
  now=$(command date -u +%s)
  tf="$cache/axonflow/throttle-until"
  mkdir -p "$cache/axonflow"
  # The helper reads the clock through `date -u +%s`: pin it. The pinned value
  # lives in its own name: the helpers declare `local now`, and bash scoping
  # is dynamic, so `echo "$now"` here would read theirs.
  _PINNED_NOW="$now"
  date() { if [ "$*" = "-u +%s" ]; then echo "$_PINNED_NOW"; else command date "$@"; fi; }

  # stamp <line> <mtime offset from now, seconds>
  stamp() {
    echo "$1" >"$tf"
    python3 -c 'import os,sys; t=float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$tf" "$((now + $2))"
  }
  # check <desc> <expected output> <expected rc> [<expect file kept: yes|no>]
  check() {
    local before; before=$(cat "$tf" 2>/dev/null)
    out=$(axonflow_governed_stamp); rc=$?
    assert_eq "$1 → prints '$2'" "$2" "$out"
    assert_eq "$1 → rc $3" "$3" "$rc"
    if [ "${4:-yes}" = "yes" ]; then
      assert_eq "$1 → the stamp is left on disk unchanged" "$before" "$(cat "$tf" 2>/dev/null)"
    else
      assert_eq "$1 → the stamp is removed" "no" "$([ -f "$tf" ] && echo yes || echo no)"
    fi
  }

  rm -f "$tf"
  out=$(axonflow_governed_stamp); rc=$?
  assert_eq "no stamp → prints nothing" "" "$out"
  assert_eq "no stamp → rc 1" "1" "$rc"

  # Rules 1 and 3: a request-rate limit, honoured for at most 300 s after it
  # was written (the deadline itself is a day out).
  for t in daily_quota per_minute; do
    stamp "$((now + 86400)) $t" -299; check "$t written 299 s ago" limit 0
    stamp "$((now + 86400)) $t" -300; check "$t written 300 s ago" "" 1
    stamp "$((now + 86400)) $t" -301; check "$t written 301 s ago" "" 1
    stamp "$((now + 86400)) $t" 0;    check "$t written now" limit 0
  done

  # Rule 4: written in the future. Up to 60 s ahead counts as written now.
  stamp "$((now + 86400)) daily_quota" 59; check "daily_quota written 59 s in the future" limit 0
  stamp "$((now + 86400)) daily_quota" 60; check "daily_quota written 60 s in the future" limit 0
  stamp "$((now + 86400)) daily_quota" 61; check "daily_quota written 61 s in the future" "" 1
  stamp "$((now + 86400)) daily_quota" 86400; check "daily_quota written a day in the future" "" 1

  # Rule 2: a feature or object-count limit gates nothing, whatever its
  # deadline or age, and is left for the plugin that wrote it (rule 5).
  for t in feature_pro_only active_policies hitl_approvals_window decision_list_size; do
    stamp "$((now + 604800)) $t" 0; check "$t written now, deadline a week out" "" 1
  done
  stamp "$((now + 3600)) some_future_limit" 0; check "an unknown limit type" "" 1

  # Rule 6: the auth_failure cooldown gates for this hook's configured length
  # from when its file was written, with rule 4's skew; the deadline in the
  # file (a week out, a millisecond epoch) never extends it.
  stamp "$((now + 60)) auth_failure" -3600;  check "auth_failure written an hour ago, 60 s left" "" 1
  stamp "$((now + 60)) auth_failure" 3600;   check "auth_failure written an hour in the future, 60 s left" "" 1
  stamp "$((now + 604800)) auth_failure" -299; check "auth_failure a week out, written 299 s ago" auth_failure 0
  stamp "$((now + 604800)) auth_failure" -300; check "auth_failure a week out, written 300 s ago" "" 1
  stamp "$((now + 604800)) auth_failure" -1200; check "auth_failure a week out, written 20 minutes ago" "" 1
  stamp "$((now * 1000)) auth_failure" 0;    check "auth_failure with a millisecond deadline, written now" auth_failure 0
  stamp "$((now * 1000)) auth_failure" -301; check "auth_failure with a millisecond deadline, written 301 s ago" "" 1
  stamp "$((now + 604800)) auth_failure" 60; check "auth_failure written 60 s in the future" auth_failure 0
  stamp "$((now + 604800)) auth_failure" 61; check "auth_failure written 61 s in the future" "" 1
  _AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS=1800
  stamp "$((now + 604800)) auth_failure" -1200; check "auth_failure written 20 minutes ago, cooldown 1800 s" auth_failure 0
  stamp "$((now + 604800)) auth_failure" -1800; check "auth_failure written 1800 s ago, cooldown 1800 s" "" 1
  _AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS=300
  # A deadline too long for bash arithmetic is malformed: cleared, no error.
  stamp "99999999999999999999 auth_failure" 0
  out=$(axonflow_governed_stamp 2>&1); rc=$?
  assert_eq "a 20-digit deadline → prints nothing (no arithmetic error)" "" "$out"
  assert_eq "a 20-digit deadline → rc 1" "1" "$rc"
  stamp "$((now * 1000)) auth_failure" 0
  assert_eq "a millisecond deadline (13 digits) is still read" "auth_failure" "$(axonflow_governed_stamp 2>&1)"
  # A cooldown that is not whole seconds reads as the default.
  local v
  for v in abc 1e3 -5 "300 x" 99999999; do
    assert_eq "AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS='$v' → 300" "300" "$(AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS="$v" bash -c '. "$1"; echo "$_AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS"' _ "$HELPER")"
  done
  assert_eq "AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS='1800' → 1800" "1800" "$(AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS=1800 bash -c '. "$1"; echo "$_AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS"' _ "$HELPER")"

  # The deadline passed, or the stamp is unreadable: cleared, as before.
  stamp "$((now - 1)) daily_quota" 0; check "daily_quota whose deadline passed" "" 1 no
  stamp "$now auth_failure" -10;      check "auth_failure whose deadline is now" "" 1 no
  stamp "not-a-number daily_quota" 0; check "a malformed stamp" "" 1 no

  # The remaining seconds and the cooldown note name the file.
  stamp "$((now + 120)) auth_failure" 0
  assert_eq "remaining seconds for a 120 s cooldown" "120" "$(axonflow_throttle_remaining_seconds)"
  assert_contains "the cooldown note names the seconds" "$(axonflow_auth_cooldown_note)" "blocked for another 120 seconds"
  assert_contains "the cooldown note names the file" "$(axonflow_auth_cooldown_note)" "$tf"
  stamp "$((now + 604800)) auth_failure" -100
  assert_eq "remaining seconds for a week-out auth_failure written 100 s ago (cooldown 300 s)" "200" "$(axonflow_throttle_remaining_seconds)"
  unset -f date
}

# ---------------------------------------------------------------------------
# Test 16: the shared file's WRITE and format are unchanged: one line,
# `<epoch> <limit_type>`, overwritten, a feature-limit envelope included and
# its resets_at uncapped (other plugins read the file and honour it their way).
# ---------------------------------------------------------------------------
test_stamp_write_format_unchanged() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"
  # shellcheck disable=SC1090
  . "$HELPER"
  local body headers tf resets expect
  tf="$cache/axonflow/throttle-until"
  resets=$(( $(date -u +%s) + 604800 ))
  body=$(mktemp); headers=$(mktemp)
  jq -nc --arg r "$(date -u -r "$resets" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$resets" +%Y-%m-%dT%H:%M:%SZ)" \
    '{error: "HITL approval window used", limit_type: "hitl_approvals_window", tier: "Free", resets_at: $r, upgrade: {wording: "HITL-WORDING", buy_url: "https://example.invalid/pricing"}}' >"$body"
  axonflow_handle_envelope_response "403" "$body" "$headers" 2>/dev/null
  assert_eq "a hitl_approvals_window envelope is still stamped" "$resets hitl_approvals_window" "$(cat "$tf")"
  assert_eq "the stamp is one line" "1" "$(wc -l <"$tf" | tr -d ' ')"
  axonflow_handle_auth_failure "401" "$body" "$headers" 2>/dev/null
  assert_contains "a 401 overwrites the same file with auth_failure" "$(cat "$tf")" " auth_failure"
  assert_eq "still one line after the overwrite" "1" "$(wc -l <"$tf" | tr -d ' ')"
  rm -f "$body" "$headers"
}

# ---------------------------------------------------------------------------
# The auth_failure cooldown is read in base 10: a leading zero is not octal.
# "08" used to fail in arithmetic ("value too great for base"), so a 401 wrote
# no cooldown stamp and every later call asked the agent again; "0010" read
# as 8.
# ---------------------------------------------------------------------------
test_cooldown_leading_zero_is_base_ten() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  local v
  for v in "08:8" "0010:10" "09:9" "0x10:300"; do
    assert_eq "AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS='${v%%:*}' → ${v##*:}" "${v##*:}" "$(AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS="${v%%:*}" bash -c '. "$1"; echo "$_AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS"' _ "$HELPER" 2>&1)"
  done
  local body headers stderr_out before epoch
  body=$(mktemp); echo '{"error":"invalid credentials"}' >"$body"
  headers=$(mktemp); printf 'HTTP/2 401\r\n' >"$headers"
  stderr_out=$(mktemp)
  before=$(date -u +%s)
  XDG_CACHE_HOME="$cache" AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS=08 bash -c '. "$1"; axonflow_handle_auth_failure 401 "$2" "$3"' _ "$HELPER" "$body" "$headers" 2>"$stderr_out"
  assert_not_contains "a 401 with AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS=08 → no arithmetic error" "$(cat "$stderr_out")" "value too great"
  epoch=$(awk 'NR==1 {print $1}' "$cache/axonflow/throttle-until" 2>/dev/null)
  if [ -n "$epoch" ] && [ "$epoch" -ge $((before + 8)) ] && [ "$epoch" -le $((before + 10)) ]; then
    assert_eq "a 401 with AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS=08 → a cooldown stamp 8 s out" "yes" "yes"
  else
    assert_eq "a 401 with AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS=08 → a cooldown stamp 8 s out" "yes" "no (epoch='$epoch' before=$before)"
  fi
  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test "T1: 429 daily-quota envelope" test_429_daily_quota
run_test "T2: 403 active_policies envelope" test_403_active_policies
run_test "T3: JSON-RPC wrapped envelope" test_jsonrpc_wrapped_envelope
run_test "T4: legacy 429 no envelope (preserve behaviour)" test_legacy_429_no_envelope_preserves_behaviour
run_test "T5: non-4xx status ignored" test_non_4xx_status_ignored
run_test "T6: once-per-day stamp suppresses second wording" test_once_per_day_stamp
run_test "T7: axonflow_throttle_active state machine" test_throttle_active_states
run_test "T8: no stdout bytes" test_no_stdout_bytes
run_test "T9: HTTP 401 stamps 5-minute throttle (#2275 fix)" test_401_auth_failure_stamps_throttle
run_test "T10: non-401 statuses not handled (envelope-handler scope guard)" test_non_401_statuses_not_handled
run_test "T11: 401 prompt suppressed on second hit same day" test_401_prompt_once_per_day
run_test "T12: 401 path emits no stdout bytes" test_401_no_stdout_bytes
run_test "T13: 401 nudge fires despite pre-stamped envelope file (#2275 v1.5.2 fix)" \
  test_401_separate_stamp_not_suppressed_by_envelope_stamp
run_test "T14: envelope nudge fires despite pre-stamped auth-failure file" \
  test_envelope_not_suppressed_by_auth_stamp
run_test "T15: the stamp rules (axonflow_governed_stamp, clock pinned)" test_governed_stamp_rules
run_test "T16: the shared stamp file's write and format are unchanged" test_stamp_write_format_unchanged
run_test "T17: the auth_failure cooldown is read in base 10" test_cooldown_leading_zero_is_base_ten

echo
echo "==============================="
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
echo "==============================="
[ "$FAIL" -eq 0 ]
