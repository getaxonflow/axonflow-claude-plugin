#!/usr/bin/env bash
# Claude Code runtime E2E: V1 paid Pro tier — X-License-Token wire-up.
#
# Asserts the plugin sends the user's paid-tier license token as the
# X-License-Token HTTP header on every governed agent request, in two
# resolution modes:
#
#   1. AXONFLOW_LICENSE_TOKEN env var set → token shipped on the wire
#   2. ~/.config/axonflow/license-token.json on disk → same token shipped
#   3. No token configured → header is ABSENT (free tier — middleware
#      passes through)
#
# Plus a 4th assertion: the platform's PluginClaimMiddleware accepts a
# token-bearing request (against the live agent — only if AGENT_URL is
# reachable; gracefully skips otherwise so this can run in CI without a
# stack).
#
# Why the wire-level assertion matters: the slash command + script could
# write the token to disk, the hook could resolve it, but if the curl
# call doesn't actually transmit the X-License-Token header the
# PluginClaimMiddleware never gates on it and the user is silently on
# free tier. The capture-server pattern catches that class of bug.
#
# ENV (all optional):
#   AGENT_URL           — live agent URL for the middleware-accepts step
#                         (default: http://localhost:8080; skipped if
#                         /health is unreachable)
#   TEST_LICENSE_TOKEN  — pre-issued AXON- token for the live-agent step
#                         (skipped if unset)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

AGENT_URL="${AGENT_URL:-http://localhost:8080}"
PRE_HOOK="${PLUGIN_DIR}/scripts/pre-tool-check.sh"
LOGIN_SH="${PLUGIN_DIR}/scripts/login.sh"

# Sanity: required files present.
for f in "$PRE_HOOK" "$LOGIN_SH" "${PLUGIN_DIR}/scripts/license-token.sh"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file missing: $f"
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not on PATH (needed for the tiny header-capture HTTP server)"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "SKIP: curl not on PATH"
  exit 0
fi

errors=0

# Stand up a tiny HTTP server that captures every inbound request's
# headers + body to a file, replies with a benign MCP-shaped allow
# response so the hook exits silently. Bound to 127.0.0.1:0 so we don't
# collide with anything.
WORKDIR=$(mktemp -d -t axonflow-license-token-runtime.XXXXXX)
CAPTURE_FILE="${WORKDIR}/capture.jsonl"
SERVER_LOG="${WORKDIR}/server.log"
LOG_FILE="${WORKDIR}/hook.log"

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # Restore any pre-existing license-token.json the user already had.
  if [ -f "${WORKDIR}/restore-license-token.json" ]; then
    mv -f "${WORKDIR}/restore-license-token.json" "${HOME}/.config/axonflow/license-token.json" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

# Save and clear any pre-existing license-token.json so this run is hermetic.
EXISTING_LT="${HOME}/.config/axonflow/license-token.json"
if [ -f "$EXISTING_LT" ]; then
  cp -p "$EXISTING_LT" "${WORKDIR}/restore-license-token.json"
  rm -f "$EXISTING_LT"
fi

# Inline Python capture server. POST any path → records headers+body to
# CAPTURE_FILE as one JSONL row, replies with a fixed MCP-shaped JSON-RPC
# allow response so pre-tool-check.sh treats the call as ALLOWED and exits
# silently with no output (its "no opinion" branch). PORT=<n> is printed
# on the first line so the parent can read the random port back out.
SERVER_PY="${WORKDIR}/capture-server.py"
cat >"$SERVER_PY" <<'PY'
import http.server
import json
import socketserver
import sys

CAPTURE_FILE = sys.argv[1]

ALLOW_RESPONSE = json.dumps({
    "jsonrpc": "2.0",
    "id": "hook-pre",
    "result": {
        "content": [{"type": "text", "text": json.dumps({
            "allowed": True,
            "policies_evaluated": 0,
        })}]
    },
}).encode("utf-8")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", errors="replace") if length > 0 else ""
        record = {
            "path": self.path,
            "headers": {k: v for k, v in self.headers.items()},
            "body": body,
        }
        with open(CAPTURE_FILE, "a") as f:
            f.write(json.dumps(record) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(ALLOW_RESPONSE)))
        self.end_headers()
        self.wfile.write(ALLOW_RESPONSE)

    def log_message(self, fmt, *args):
        # Suppress default access log so $SERVER_LOG stays clean.
        return


with socketserver.TCPServer(("127.0.0.1", 0), Handler) as srv:
    print(f"PORT={srv.server_address[1]}", flush=True)
    srv.serve_forever()
PY

python3 -u "$SERVER_PY" "$CAPTURE_FILE" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait up to 5s for the server to print PORT=...
PORT=""
for _ in $(seq 1 50); do
  PORT=$(grep -oE 'PORT=[0-9]+' "$SERVER_LOG" 2>/dev/null | head -1 | cut -d= -f2)
  if [ -n "$PORT" ]; then break; fi
  sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "FAIL: capture server did not start; log: $(cat "$SERVER_LOG")"
  exit 1
fi
ENDPOINT="http://127.0.0.1:$PORT"
echo "--- Capture server listening on $ENDPOINT ---"

# Helper: invoke pre-tool-check.sh with a Bash-tool-style input that has
# a real STATEMENT (otherwise the hook exits early without making the
# HTTP call). Extra args (e.g. KEY=VAL pairs) become extra env-var
# assignments injected before $PRE_HOOK. We can't use "$@" with set -u
# when zero args are passed, so guard explicitly.
fire_hook() {
  : >"$CAPTURE_FILE"  # reset capture
  : >"$LOG_FILE"
  if [ "$#" -gt 0 ]; then
    echo '{"tool_name":"Bash","tool_input":{"command":"echo runtime-e2e-license-token-probe"}}' \
      | env -i \
        HOME="$HOME" \
        PATH="$PATH" \
        AXONFLOW_ENDPOINT="$ENDPOINT" \
        AXONFLOW_TELEMETRY=off \
        AXONFLOW_PLUGIN_VERSION_CHECK=off \
        "$@" \
        "$PRE_HOOK" >/dev/null 2>"$LOG_FILE" || true
  else
    echo '{"tool_name":"Bash","tool_input":{"command":"echo runtime-e2e-license-token-probe"}}' \
      | env -i \
        HOME="$HOME" \
        PATH="$PATH" \
        AXONFLOW_ENDPOINT="$ENDPOINT" \
        AXONFLOW_TELEMETRY=off \
        AXONFLOW_PLUGIN_VERSION_CHECK=off \
        "$PRE_HOOK" >/dev/null 2>"$LOG_FILE" || true
  fi
}

# Returns 0 if the most recent capture has the X-License-Token header set
# to the given value (case-insensitive header match per HTTP spec).
assert_header() {
  local expected_value="$1"
  if [ ! -s "$CAPTURE_FILE" ]; then
    return 1
  fi
  jq -e --arg v "$expected_value" \
    'select(.headers["X-License-Token"] == $v or .headers["x-license-token"] == $v)' \
    "$CAPTURE_FILE" >/dev/null 2>&1
}

# Returns 0 if NO row in the capture has any X-License-Token header
# (case-insensitive).
assert_no_header() {
  if [ ! -s "$CAPTURE_FILE" ]; then
    return 1
  fi
  ! jq -e \
    'select(.headers["X-License-Token"] != null or .headers["x-license-token"] != null)' \
    "$CAPTURE_FILE" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Test 1: NO token configured → X-License-Token absent on the wire.
# -----------------------------------------------------------------------------
echo "Test 1: free tier (no token configured) → X-License-Token absent"
fire_hook
if assert_no_header; then
  echo "  PASS: no X-License-Token header sent (free tier behaviour intact)"
else
  echo "  FAIL: X-License-Token header sent when no token configured"
  echo "  capture: $(cat "$CAPTURE_FILE")"
  errors=$((errors + 1))
fi

# -----------------------------------------------------------------------------
# Test 2: AXONFLOW_LICENSE_TOKEN env var → header on the wire.
# -----------------------------------------------------------------------------
echo "Test 2: AXONFLOW_LICENSE_TOKEN env var → header on the wire"
ENV_TOKEN="AXON-runtime-e2e-env-token-32chars-minimum-1234567890abcdef"
fire_hook AXONFLOW_LICENSE_TOKEN="$ENV_TOKEN"
if assert_header "$ENV_TOKEN"; then
  echo "  PASS: X-License-Token: <env value> sent on the wire"
else
  echo "  FAIL: env-set token did not appear in X-License-Token header"
  echo "  capture: $(cat "$CAPTURE_FILE")"
  errors=$((errors + 1))
fi

# Also assert the mode-clarity stderr surfaces "Pro tier active".
if grep -q "Pro tier active" "$LOG_FILE"; then
  echo "  PASS: stderr surfaces 'Pro tier active' canary"
else
  echo "  FAIL: 'Pro tier active' canary missing from stderr"
  errors=$((errors + 1))
fi

# -----------------------------------------------------------------------------
# Test 3: ~/.config/axonflow/license-token.json on disk → header on wire.
# Uses the /axonflow-login slash-command implementation (login.sh) to write
# the file — proves the slash command actually writes a file the hook reads.
# -----------------------------------------------------------------------------
echo "Test 3: file-on-disk (via /axonflow-login) → header on the wire"
DISK_TOKEN="AXON-runtime-e2e-disk-token-32chars-minimum-1234567890abcdef"
"$LOGIN_SH" "$DISK_TOKEN" >/dev/null 2>&1 || true
if [ ! -f "$EXISTING_LT" ]; then
  echo "  FAIL: login.sh did not write $EXISTING_LT"
  errors=$((errors + 1))
else
  fire_hook  # no env var; file-on-disk is the only source
  if assert_header "$DISK_TOKEN"; then
    echo "  PASS: X-License-Token: <disk value> sent on the wire (slash-cmd write → hook read)"
  else
    echo "  FAIL: disk-stored token did not appear in X-License-Token header"
    echo "  capture: $(cat "$CAPTURE_FILE")"
    errors=$((errors + 1))
  fi
fi

# -----------------------------------------------------------------------------
# Test 4: env var WINS over file when both are set.
# -----------------------------------------------------------------------------
echo "Test 4: env var precedence over file"
fire_hook AXONFLOW_LICENSE_TOKEN="$ENV_TOKEN"
if assert_header "$ENV_TOKEN"; then
  echo "  PASS: env var wins (AXONFLOW_LICENSE_TOKEN beats license-token.json)"
else
  echo "  FAIL: env var did not take precedence over file"
  echo "  capture: $(cat "$CAPTURE_FILE")"
  errors=$((errors + 1))
fi

# Clean up the file we wrote so subsequent test runs are hermetic.
rm -f "$EXISTING_LT"

# -----------------------------------------------------------------------------
# Test 5 (optional, requires live AGENT_URL + TEST_LICENSE_TOKEN):
# the agent's PluginClaimMiddleware accepts a real token-bearing request.
#
# We hit /api/v1/register (Community-SaaS bootstrap endpoint). Important:
# /api/request has its own tenant-credential auth that returns 401 BEFORE
# any X-License-Token check, which would mask the middleware's verdict and
# wrongly look like a middleware-reject. /api/v1/register sits behind the
# PluginClaimMiddleware (mounted on globalRouter) but does NOT require
# tenant credentials, so the only 401 it can produce in this test path is
# "Invalid plugin license token" from the middleware itself.
#
# We use a unique X-Forwarded-For per run to avoid the agent's in-memory
# IP-based registration rate limiter (5/hr/IP) — same rationale as the
# recovery test.
# -----------------------------------------------------------------------------
if [ -n "${TEST_LICENSE_TOKEN:-}" ] && curl -sSf -o /dev/null --max-time 5 "$AGENT_URL/health" 2>/dev/null; then
  echo "Test 5: live agent accepts the AXON- token (PluginClaimMiddleware)"

  # Unique per-run XFF (avoid registration IP rate limit on dev machines
  # where this test runs many times against localhost).
  TEST5_XFF="10.99.$(( ( $$ % 200 ) + 30 )).$(( ( $(date +%s) % 200 ) + 30 ))"
  REG_EMAIL="rt-e2e-license-mw-$$-$(date +%s)@axonflow-test.invalid"
  REG_BODY=$(jq -nc --arg e "$REG_EMAIL" '{label: "rt-e2e-mw-probe", email: $e}')

  RESP_FILE=$(mktemp -t axonflow-mw-probe.XXXXXX)
  HTTP_CODE=$(curl -sS -o "$RESP_FILE" -w "%{http_code}" -X POST "$AGENT_URL/api/v1/register" \
    -H "Content-Type: application/json" \
    -H "X-Forwarded-For: $TEST5_XFF" \
    -H "X-License-Token: $TEST_LICENSE_TOKEN" \
    -d "$REG_BODY" 2>/dev/null || echo "000")
  RESP_BODY=$(cat "$RESP_FILE" 2>/dev/null || echo "")
  rm -f "$RESP_FILE"

  case "$HTTP_CODE" in
    2*)
      echo "  PASS: PluginClaimMiddleware accepted the token (HTTP $HTTP_CODE on /api/v1/register)"
      ;;
    401)
      # Disambiguate middleware-reject ("Invalid plugin license token") from
      # any other 401 path. The middleware's exact rejection messages live
      # in platform/agent/plugin_claim_middleware.go.
      if echo "$RESP_BODY" | grep -qiE 'invalid plugin license token|license not found|license has been revoked'; then
        echo "  FAIL: PluginClaimMiddleware rejected the token (HTTP 401: $RESP_BODY)"
        errors=$((errors + 1))
      else
        echo "  NOTE: HTTP 401 but body does not look like middleware rejection — body: $RESP_BODY"
      fi
      ;;
    403)
      echo "  FAIL: PluginClaimMiddleware reported tenant mismatch (HTTP 403: $RESP_BODY)"
      errors=$((errors + 1))
      ;;
    429)
      echo "  NOTE: registration rate-limited (HTTP 429) — middleware accepted token (request proceeded past the middleware)"
      ;;
    *)
      echo "  NOTE: agent returned HTTP $HTTP_CODE — not 401/403, so token wasn't rejected by middleware. body: $RESP_BODY"
      ;;
  esac
else
  echo "Test 5: SKIP (set TEST_LICENSE_TOKEN + reachable AGENT_URL=$AGENT_URL/health to exercise live middleware)"
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors assertion(s) failed"
  exit 1
fi

echo ""
echo "PASS: license-token wire-up verified end-to-end"
