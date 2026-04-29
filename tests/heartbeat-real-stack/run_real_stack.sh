#!/usr/bin/env bash
# Real-stack E2E harness for the claude-code-plugin Community-SaaS-default
# rollout (ADR-048).
#
# Drives the plugin through its actual public hook entry point
# (scripts/pre-tool-check.sh) twice:
#
#   Run 1 — COLD START. Sandboxed HOME, no registration file, no telemetry
#   stamp. Expectations:
#     1. pre-tool-check.sh returns exit 0.
#     2. Mode-clarity canary on stderr: "[AxonFlow] Connected to AxonFlow at
#        http://127.0.0.1:<port> (mode=community-saas)".
#     3. Bootstrap registers against the fake /api/v1/register and persists
#        ~/.config/axonflow/try-registration.json (mode 0600).
#     4. Telemetry heartbeat fires once (counter goes 0 → 1) with
#        deployment_mode=community-saas.
#     5. Telemetry stamp file written (mode 0600).
#
#   Run 2 — WARM CACHE. Same sandbox HOME. Expectations:
#     1. pre-tool-check.sh returns exit 0.
#     2. Bootstrap reads cached registration (no fresh /register call).
#     3. Telemetry heartbeat is suppressed by the 7-day stamp gate
#        (counter delta = 0).
#
# Cross-platform: tested on Ubuntu, macOS, and Windows (WSL2 / Git Bash).
# Requires: bash, curl, jq, python3, mktemp, stat.
#
# Override the agent endpoint by setting AXONFLOW_REAL_STACK_PORT before
# invoking; defaults to a random ephemeral port chosen by the OS.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
PRE_TOOL="${PLUGIN_DIR}/scripts/pre-tool-check.sh"

if [ ! -x "$PRE_TOOL" ]; then
  echo "FAIL: pre-tool-check.sh not found or not executable at $PRE_TOOL" >&2
  exit 1
fi

# Pick a free port if not pinned.
PORT="${AXONFLOW_REAL_STACK_PORT:-0}"
if [ "$PORT" = "0" ]; then
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
fi

WORK_DIR=$(mktemp -d)
SANDBOX_HOME=$(mktemp -d)
trap 'rm -rf "$WORK_DIR" "$SANDBOX_HOME"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

# Start the fake server. Python's stdout buffering is flushed via flush=True
# in server.py so the readiness line lands deterministically.
python3 "$HARNESS_DIR/server.py" "$PORT" "$WORK_DIR" >"$WORK_DIR/_server.out" 2>&1 &
SERVER_PID=$!

# Wait for the readiness sentinel with a 30s budget. The file-based signal
# is the authoritative one — Python's stdout can be block-buffered when
# redirected to a file even with flush=True on some macOS GH runners.
deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$WORK_DIR/_server_ready" ]; then
    break
  fi
  sleep 0.1
done
if [ ! -f "$WORK_DIR/_server_ready" ]; then
  echo "FAIL: server did not start within 30s" >&2
  echo "--- server stdout/stderr ---" >&2
  cat "$WORK_DIR/_server.out" >&2 || true
  exit 1
fi

ENDPOINT="http://127.0.0.1:${PORT}"
CHECKPOINT_URL="${ENDPOINT}/v1/ping"

# Read counter helper.
counter() {
  cat "$WORK_DIR/_counter" 2>/dev/null || echo "0"
}

PASSED=0
FAILED=0
fail() {
  echo "  FAIL: $1" >&2
  FAILED=$((FAILED + 1))
}
pass() {
  echo "  PASS: $1"
  PASSED=$((PASSED + 1))
}

# ---------------------------------------------------------------------------
# Run 1: COLD START
# ---------------------------------------------------------------------------
echo "--- Cold start: bootstrap + first heartbeat ---"

# Critical: clear AXONFLOW_ENDPOINT/AUTH so the resolver picks community-saas.
# AXONFLOW_CHECKPOINT_URL points the heartbeat at our fake instead of the
# real checkpoint.getaxonflow.com.
COLD_STDIN='{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'

# IMPORTANT: the plugin's bootstrap pings https://try.getaxonflow.com directly
# (it's hardcoded in community-saas-bootstrap.sh). For a localhost-only test
# we override AXONFLOW_TELEMETRY=off (heartbeat-only stays under
# AXONFLOW_CHECKPOINT_URL control, but registration always uses the
# hardcoded production URL). To test the full registration path against the
# fake, we set AXONFLOW_REGISTER_URL — supported by tests/heartbeat-real-stack
# but NOT by the production bootstrap. We rely on the harness running with a
# patched bootstrap variant via AXONFLOW_HARNESS=1 detection in the
# bootstrap script (added below). When AXONFLOW_HARNESS=1, the bootstrap
# uses ${AXONFLOW_HARNESS_REGISTER_URL:-prod-default}.
COLD_OUT=$(
  env -i \
    HOME="$SANDBOX_HOME" \
    PATH="$PATH" \
    AXONFLOW_TELEMETRY="" \
    AXONFLOW_CHECKPOINT_URL="$CHECKPOINT_URL" \
    AXONFLOW_HARNESS=1 \
    AXONFLOW_HARNESS_REGISTER_URL="${ENDPOINT}/api/v1/register" \
    AXONFLOW_HARNESS_AGENT_ENDPOINT="$ENDPOINT" \
    bash "$PRE_TOOL" <<<"$COLD_STDIN" 2>"$WORK_DIR/_cold_stderr"
)
COLD_RC=$?

# Telemetry is fire-and-forget background; give it time to land.
sleep 2

# Assertion 1: exit 0.
if [ "$COLD_RC" -eq 0 ]; then
  pass "cold-start exit 0"
else
  fail "cold-start exit $COLD_RC"
fi

# Assertion 2: canary on stderr.
if grep -q "^\[AxonFlow\] Connected to AxonFlow at ${ENDPOINT} (mode=community-saas)$" "$WORK_DIR/_cold_stderr"; then
  pass "canary line on stderr matches fake endpoint + community-saas"
else
  fail "canary line missing or mismatched"
  cat "$WORK_DIR/_cold_stderr" >&2
fi

# Assertion 3: registration file created at correct path with mode 0600.
REG_FILE="${SANDBOX_HOME}/.config/axonflow/try-registration.json"
if [ -f "$REG_FILE" ]; then
  pass "registration file written"
  REG_MODE=$(stat -c %a "$REG_FILE" 2>/dev/null) || REG_MODE=""
  case "$REG_MODE" in ''|*[!0-9]*) REG_MODE=$(stat -f %Lp "$REG_FILE" 2>/dev/null) || REG_MODE="" ;; esac
  case "$REG_MODE" in ''|*[!0-9]*) REG_MODE="" ;; esac
  if [ "$REG_MODE" = "600" ] || [ "$REG_MODE" = "0600" ]; then
    pass "registration file mode is 0600"
  else
    fail "registration file mode is $REG_MODE (expected 0600)"
  fi
  REG_TENANT=$(jq -r '.tenant_id' "$REG_FILE" 2>/dev/null)
  case "$REG_TENANT" in
    cs_*) pass "registration file holds a cs_<uuid> tenant_id ($REG_TENANT)" ;;
    *) fail "registration file tenant_id is not cs_*: $REG_TENANT" ;;
  esac
else
  fail "registration file not written at $REG_FILE"
fi

# Assertion 4: telemetry heartbeat fired once.
COLD_COUNTER=$(counter)
if [ "$COLD_COUNTER" = "1" ]; then
  pass "telemetry heartbeat fired exactly once (counter=1)"
else
  fail "telemetry counter is $COLD_COUNTER (expected 1)"
fi

# Assertion 5: deployment_mode=community-saas in the captured ping.
if [ -f "$WORK_DIR/_pings.jsonl" ]; then
  COLD_MODE=$(jq -r '.deployment_mode' "$WORK_DIR/_pings.jsonl" | head -1)
  if [ "$COLD_MODE" = "community-saas" ]; then
    pass "ping deployment_mode=community-saas"
  else
    fail "ping deployment_mode=$COLD_MODE (expected community-saas)"
  fi
fi

# Assertion 6: telemetry stamp file written, mode 0600.
STAMP_FILE="${SANDBOX_HOME}/.cache/axonflow/claude-code-plugin-telemetry-sent"
if [ -f "$STAMP_FILE" ]; then
  pass "telemetry stamp file written"
  STAMP_MODE=$(stat -c %a "$STAMP_FILE" 2>/dev/null) || STAMP_MODE=""
  case "$STAMP_MODE" in ''|*[!0-9]*) STAMP_MODE=$(stat -f %Lp "$STAMP_FILE" 2>/dev/null) || STAMP_MODE="" ;; esac
  case "$STAMP_MODE" in ''|*[!0-9]*) STAMP_MODE="" ;; esac
  if [ "$STAMP_MODE" = "600" ] || [ "$STAMP_MODE" = "0600" ]; then
    pass "telemetry stamp file mode is 0600"
  else
    fail "telemetry stamp file mode is $STAMP_MODE (expected 0600)"
  fi
else
  fail "telemetry stamp file not written at $STAMP_FILE"
fi

# ---------------------------------------------------------------------------
# Run 2: WARM CACHE
# ---------------------------------------------------------------------------
echo ""
echo "--- Warm cache: stamp gate + cached registration ---"

WARM_REG_BEFORE=$(wc -l < "$WORK_DIR/_registrations.jsonl" 2>/dev/null || echo 0)
WARM_COUNTER_BEFORE=$(counter)

env -i \
  HOME="$SANDBOX_HOME" \
  PATH="$PATH" \
  AXONFLOW_TELEMETRY="" \
  AXONFLOW_CHECKPOINT_URL="$CHECKPOINT_URL" \
  AXONFLOW_HARNESS=1 \
  AXONFLOW_HARNESS_REGISTER_URL="${ENDPOINT}/api/v1/register" \
  AXONFLOW_HARNESS_AGENT_ENDPOINT="$ENDPOINT" \
  bash "$PRE_TOOL" <<<"$COLD_STDIN" >/dev/null 2>>"$WORK_DIR/_warm_stderr"
WARM_RC=$?

sleep 2

if [ "$WARM_RC" -eq 0 ]; then
  pass "warm-cache exit 0"
else
  fail "warm-cache exit $WARM_RC"
fi

# Bootstrap should have used the cached registration → no new POST /register.
WARM_REG_AFTER=$(wc -l < "$WORK_DIR/_registrations.jsonl" 2>/dev/null || echo 0)
if [ "$WARM_REG_AFTER" -eq "$WARM_REG_BEFORE" ]; then
  pass "no new registration POST (cached path)"
else
  fail "warm-cache fired $((WARM_REG_AFTER - WARM_REG_BEFORE)) extra registration(s)"
fi

# Telemetry counter should not advance (7-day stamp gate).
WARM_COUNTER_AFTER=$(counter)
if [ "$WARM_COUNTER_AFTER" = "$WARM_COUNTER_BEFORE" ]; then
  pass "telemetry suppressed by stamp gate (delta=0)"
else
  fail "telemetry counter went $WARM_COUNTER_BEFORE → $WARM_COUNTER_AFTER (expected delta 0)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo " Real-stack E2E summary"
echo "========================================"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
[ "$FAILED" -eq 0 ]
