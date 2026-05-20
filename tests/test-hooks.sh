#!/usr/bin/env bash
# Regression tests for AxonFlow Claude Code plugin hooks.
# Tests the pre-tool-check.sh and post-tool-audit.sh scripts
# against a mock MCP server (or live AxonFlow if running).
#
# Usage:
#   ./tests/test-hooks.sh              # Uses mock server (no AxonFlow needed)
#   ./tests/test-hooks.sh --live       # Tests against live AxonFlow on localhost:8080
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"
POST_HOOK="$PLUGIN_DIR/scripts/post-tool-audit.sh"

PASS=0
FAIL=0
MOCK_PID=""
# MOCK_PORT is allocated dynamically by start_mock_server so consecutive test
# runs don't collide on TIME_WAIT (issue #85). Initialized empty here so the
# unset-set check in start_mock_server doesn't trip set -u.
MOCK_PORT=""

# --- Test Helpers ---

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        ((FAIL++)) || true
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    else
        echo "  FAIL: $desc (expected '$needle' in output)"
        ((FAIL++)) || true
    fi
}

assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    else
        echo "  FAIL: $desc (expected empty, got '$actual')"
        ((FAIL++)) || true
    fi
}

# --- Mock MCP Server ---
# A tiny HTTP server that returns configurable JSON-RPC responses.

assert_file_exists() {
    local desc="$1" path="$2"
    if [ -f "$path" ]; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    else
        echo "  FAIL: $desc (file not found: $path)"
        ((FAIL++)) || true
    fi
}

assert_file_not_exists() {
    local desc="$1" path="$2"
    if [ ! -f "$path" ]; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    else
        echo "  FAIL: $desc (file should not exist: $path)"
        ((FAIL++)) || true
    fi
}

assert_json_field() {
    local desc="$1" json="$2" field="$3" expected="${4:-}"
    local val
    val=$(echo "$json" | jq -r ".$field // empty" 2>/dev/null || echo "")
    if [ -z "$val" ]; then
        echo "  FAIL: $desc (field .$field missing or empty)"
        ((FAIL++)) || true
    elif [ -n "$expected" ] && [ "$val" != "$expected" ]; then
        echo "  FAIL: $desc (.$field = '$val', expected '$expected')"
        ((FAIL++)) || true
    else
        echo "  PASS: $desc"
        ((PASS++)) || true
    fi
}

# --- Mock MCP Server ---
# A tiny HTTP server that returns configurable JSON-RPC responses.
# Also handles /health and /v1/ping for telemetry tests.

TELEMETRY_CAPTURE_FILE=""

start_mock_server() {
    TELEMETRY_CAPTURE_FILE=$(mktemp)
    local port_file
    port_file=$(mktemp)
    # Python mock server that responds based on the statement content. Binds
    # to port 0 (ephemeral) and writes the assigned port back so the rest of
    # the test reads the actual port — prevents TIME_WAIT collisions between
    # consecutive runs that previously caused storm-of-failures in run N+1
    # after run N (issue #85).
    python3 -c "
import http.server, json, sys, os as _os, threading as _threading

TELEMETRY_FILE = '$TELEMETRY_CAPTURE_FILE'
PORT_FILE = '$port_file'

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            resp = {'version': '7.0.1', 'status': 'healthy'}
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(resp).encode())
        elif self.path == '/v1/ping/last':
            try:
                with open(TELEMETRY_FILE, 'r') as f:
                    data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(data.encode())
            except:
                self.send_response(404)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(length) if length > 0 else b''

        # Telemetry ping endpoint. Concurrent POSTs from backgrounded probes
        # in pre-tool-check.sh + the foreground telemetry test can race on
        # TELEMETRY_FILE. Use atomic write (tmp + rename) so a partial /
        # interleaved write from a concurrent thread can't appear to a
        # reader as a truncated file (issue #85 — caused 'sdk field missing'
        # failures in the 'payload has required fields' test).
        if self.path == '/v1/ping':
            tmp = TELEMETRY_FILE + '.' + str(_os.getpid()) + '.' + str(_threading.get_ident()) + '.tmp'
            with open(tmp, 'w') as f:
                f.write(raw.decode('utf-8', errors='replace'))
                f.flush()
                _os.fsync(f.fileno())
            _os.replace(tmp, TELEMETRY_FILE)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{\"ok\":true}')
            return

        body = json.loads(raw) if raw else {}

        params = body.get('params', {})
        tool_name = params.get('name', '')
        args = params.get('arguments', {})
        statement = args.get('statement', '')

        # Simulate different responses based on statement content.
        # v0.3.1: additional trigger strings for the v0.3.0 decision matrix
        # that was untested.
        if 'FAIL_CLOSED_METHOD' in statement:
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'error': {'code': -32601, 'message': 'Method not found'}}
        elif 'FAIL_CLOSED_PARAMS' in statement:
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'error': {'code': -32602, 'message': 'Invalid params'}}
        elif 'FAIL_OPEN_INTERNAL' in statement:
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'error': {'code': -32603, 'message': 'Internal error'}}
        elif 'FAIL_OPEN_PARSE' in statement:
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'error': {'code': -32700, 'message': 'Parse error'}}
        elif 'FAIL_OPEN_UNKNOWN' in statement:
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'error': {'code': -99999, 'message': 'Unknown code'}}
        elif 'AUTH_ERROR' in statement:
            # JSON-RPC auth error
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'error': {'code': -32001, 'message': 'Authentication failed'}}
        elif 'HTTP_401_WITH_32001' in statement:
            # HTTP 401 with a JSON-RPC -32001 body — the documented #2275
            # follow-up carve-out: the throttle path MUST NOT swallow this
            # response. The plugin must route through the -32001 fail-closed
            # deny branch (issue #1545 Direction 3) so the operator sees
            # the auth failure as a structured deny, not 5 minutes of silent
            # fall-open.
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'error': {'code': -32001, 'message': 'Authentication failed'}}
            self.send_response(401)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(resp).encode())
            return
        elif 'HTTP_401_NO_32001' in statement:
            # HTTP 401 with a non-32001 body shape — the standard #2275
            # throttle path: plugin stamps `throttle-until` + fires the
            # once-per-day credential-refresh nudge to stderr + exits 0
            # (fall-open). This is the auth-storm prevention path.
            resp = {'error': 'invalid credentials'}
            self.send_response(401)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(resp).encode())
            return
        elif 'BLOCKED' in statement:
            # Policy blocks the command
            result_text = json.dumps({'allowed': False, 'block_reason': 'Test policy violation', 'policies_evaluated': 10})
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'result': {'content': [{'type': 'text', 'text': result_text}]}}
        elif tool_name == 'audit_tool_call':
            result_text = json.dumps({'recorded': True, 'tool_name': args.get('tool_name', 'test')})
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'result': {'content': [{'type': 'text', 'text': result_text}]}}
        elif tool_name == 'check_output':
            msg = args.get('message', '')
            if 'SSN' in msg or '123-45' in msg:
                result_text = json.dumps({'allowed': True, 'redacted_message': 'SSN: [REDACTED]', 'policies_evaluated': 5})
            else:
                result_text = json.dumps({'allowed': True, 'policies_evaluated': 5})
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'result': {'content': [{'type': 'text', 'text': result_text}]}}
        else:
            # Default: allow
            result_text = json.dumps({'allowed': True, 'policies_evaluated': 10})
            resp = {'jsonrpc': '2.0', 'id': body.get('id'), 'result': {'content': [{'type': 'text', 'text': result_text}]}}

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(resp).encode())

    def log_message(self, format, *args):
        pass  # Suppress logs

# ThreadingHTTPServer handles concurrent requests. The previous single-threaded
# HTTPServer caused intermittent test failures (issue #85) because
# pre-tool-check.sh backgrounds version-check.sh which probes /health
# concurrently with the next test's foreground curl. With a sequential server
# the foreground request queued behind the backgrounded one and could time out
# under load, producing the swinging-failure-count pattern (0/0/15 etc).
#
# Python's default request_queue_size (socket listen backlog) is 5, which
# is too small for the load this test creates (14+ POSTs + 6+ backgrounded
# /health probes in rapid succession). On macOS, an undersized backlog
# makes the kernel drop new SYNs once the queue fills, surfacing in curl
# as 'Connection timed out' on a perfectly healthy server. Bumping to 256
# eliminated the remaining intermittent /v1/ping POST timeouts.
class S(http.server.ThreadingHTTPServer):
    request_queue_size = 256
    allow_reuse_address = True
srv = S(('127.0.0.1', 0), Handler)
with open(PORT_FILE, 'w') as _f:
    _f.write(str(srv.server_address[1]))
srv.serve_forever()
" &
    MOCK_PID=$!

    # Wait for the server to write its assigned port. Without this the test
    # would race the Python startup; a slow CI runner could let the first
    # few hook calls fire before MOCK_PORT was resolvable.
    local attempts=0
    while [ "$attempts" -lt 50 ]; do
        if [ -s "$port_file" ]; then
            MOCK_PORT=$(cat "$port_file")
            break
        fi
        attempts=$((attempts + 1))
        sleep 0.1
    done
    rm -f "$port_file"
    if [ -z "$MOCK_PORT" ]; then
        echo "FATAL: mock server did not write its port after 5s" >&2
        return 1
    fi

    # Readiness probe — confirm the bound port is actually accepting requests.
    attempts=0
    while [ "$attempts" -lt 30 ]; do
        if curl -sf -o /dev/null --max-time 1 "http://127.0.0.1:$MOCK_PORT/health" 2>/dev/null; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.1
    done
    echo "FATAL: mock server did not respond on port $MOCK_PORT after 3s" >&2
    return 1
}

stop_mock_server() {
    if [ -n "$MOCK_PID" ]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    if [ -n "$TELEMETRY_CAPTURE_FILE" ] && [ -f "$TELEMETRY_CAPTURE_FILE" ]; then
        rm -f "$TELEMETRY_CAPTURE_FILE"
    fi
}

# --- Setup ---

if [ "${1:-}" = "--live" ]; then
    echo "=== Running against live AxonFlow ==="
    ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
    AUTH="${AXONFLOW_AUTH:-$(echo -n 'demo:demo-secret' | base64)}"
else
    echo "=== Running against mock MCP server ==="
    start_mock_server
    trap stop_mock_server EXIT
    ENDPOINT="http://127.0.0.1:$MOCK_PORT"
    AUTH=""
fi

export AXONFLOW_ENDPOINT="$ENDPOINT"
export AXONFLOW_AUTH="$AUTH"

# Suppress telemetry during hook tests — telemetry-ping.sh is backgrounded
# from pre-tool-check.sh, so without this, every hook test would attempt a
# real ping to checkpoint.getaxonflow.com. The dedicated telemetry test
# section below explicitly unsets this to test the telemetry path.
export AXONFLOW_TELEMETRY=off

echo ""

# ============================================================
# PreToolUse Hook Tests
# ============================================================

echo "--- PreToolUse: allowed:true → allow ---"
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | "$PRE_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Exit code is 0" "0" "$EXIT_CODE"
assert_empty "No output (silent allow)" "$OUTPUT"

echo ""
echo "--- PreToolUse: allowed:false → deny ---"
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"BLOCKED rm -rf /"}}' | "$PRE_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Exit code is 0 (structured deny)" "0" "$EXIT_CODE"
assert_contains "Has permissionDecision" "$OUTPUT" "permissionDecision"
assert_contains "Decision is deny" "$OUTPUT" '"deny"'
assert_contains "Has policy reason" "$OUTPUT" "policy violation"

echo ""
echo "--- PreToolUse: JSON-RPC auth error → deny ---"
if [ "${1:-}" = "--live" ]; then
    echo "  SKIP: Auth error test only works with mock server (live AxonFlow has no AUTH_ERROR trigger)"
    ((PASS++)) || true
else
    OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"AUTH_ERROR test"}}' | "$PRE_HOOK" 2>/dev/null)
    EXIT_CODE=$?
    assert_eq "Exit code is 0" "0" "$EXIT_CODE"
    assert_contains "Has permissionDecision" "$OUTPUT" "permissionDecision"
    assert_contains "Decision is deny" "$OUTPUT" '"deny"'
    assert_contains "Has governance blocked" "$OUTPUT" "governance blocked"
fi

echo ""
echo "--- PreToolUse: HTTP 401 + JSON-RPC -32001 → deny (carve-out) ---"
# Regression guard for the v1.5.1 → v1.5.2 carve-out: the v1.5.1 fix wired
# axonflow_handle_auth_failure ahead of the JSON-RPC parser, so an HTTP 401
# whose body carries the documented -32001 envelope would have fallen
# through the throttle path (exit 0, no deny) — losing the pre-existing
# fail-closed semantics. The carve-out in pre-tool-check.sh inspects the
# JSON-RPC code BEFORE calling axonflow_handle_auth_failure and skips the
# throttle path when code == -32001, so the deny branch fires unchanged.
#
# Each invocation gets an isolated XDG_CACHE_HOME so a 401 from a prior
# test doesn't pre-stamp the throttle file and steal this test's exit
# path (`axonflow_throttle_active` would short-circuit before reaching
# either branch).
if [ "${1:-}" = "--live" ]; then
    echo "  SKIP: mock-only trigger"
    ((PASS++)) || true
else
    TMP_CACHE_32001=$(mktemp -d -t axonflow-32001.XXXXXX)
    OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"HTTP_401_WITH_32001 test"}}' | \
        XDG_CACHE_HOME="$TMP_CACHE_32001" "$PRE_HOOK" 2>/dev/null)
    EXIT_CODE=$?
    assert_eq "Exit code is 0 (structured deny output)" "0" "$EXIT_CODE"
    assert_contains "Has permissionDecision" "$OUTPUT" "permissionDecision"
    assert_contains "Decision is deny (carve-out preserves -32001 semantics)" "$OUTPUT" '"deny"'
    assert_contains "Has governance blocked" "$OUTPUT" "governance blocked"
    # Belt-and-suspenders: the throttle file MUST NOT be stamped on the
    # -32001 carve-out path. If it were, a subsequent (legitimate) call
    # would be silenced by axonflow_throttle_active.
    assert_file_not_exists "throttle-until NOT stamped on -32001 carve-out" \
        "$TMP_CACHE_32001/axonflow/throttle-until"
    rm -rf "$TMP_CACHE_32001"
fi

echo ""
echo "--- PreToolUse: HTTP 401 without -32001 → allow (throttle path) ---"
# Sibling guard: an HTTP 401 whose body is NOT a -32001 JSON-RPC envelope
# still routes through axonflow_handle_auth_failure → throttle + fall-open
# (exit 0, no deny output). Confirms the carve-out's predicate is narrow
# enough not to swallow the auth-storm prevention path itself.
if [ "${1:-}" = "--live" ]; then
    echo "  SKIP: mock-only trigger"
    ((PASS++)) || true
else
    TMP_CACHE_401=$(mktemp -d -t axonflow-401.XXXXXX)
    OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"HTTP_401_NO_32001 test"}}' | \
        XDG_CACHE_HOME="$TMP_CACHE_401" "$PRE_HOOK" 2>/dev/null)
    EXIT_CODE=$?
    assert_eq "Exit code is 0 (fall-open)" "0" "$EXIT_CODE"
    assert_empty "No deny output (auth-storm throttle path runs)" "$OUTPUT"
    assert_file_exists "throttle-until IS stamped on plain 401" \
        "$TMP_CACHE_401/axonflow/throttle-until"
    rm -rf "$TMP_CACHE_401"
fi

echo ""
echo "--- PreToolUse: network failure → allow (fail-open) ---"
# Run hook in a subshell with overridden endpoint pointing to a port nothing listens on.
# The env var must apply to the hook process, not just the echo.
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo test"}}' | AXONFLOW_ENDPOINT="http://127.0.0.1:19999" "$PRE_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Exit code is 0 (fail-open)" "0" "$EXIT_CODE"
assert_empty "No output (silent allow on network failure)" "$OUTPUT"

# v0.3.1 decision-matrix coverage (review finding H3)
# Claude Code hooks use JSON output with permissionDecision, not exit 2.

echo ""
echo "--- PreToolUse: -32601 method not found → deny ---"
if [ "${1:-}" = "--live" ]; then
    echo "  SKIP: mock-only trigger"
    ((PASS++)) || true
else
    OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"FAIL_CLOSED_METHOD"}}' | "$PRE_HOOK" 2>/dev/null)
    EXIT_CODE=$?
    assert_eq "Exit code is 0" "0" "$EXIT_CODE"
    assert_contains "Decision is deny" "$OUTPUT" '"deny"'
    assert_contains "Has governance blocked" "$OUTPUT" "governance blocked"
fi

echo ""
echo "--- PreToolUse: -32602 invalid params → deny ---"
if [ "${1:-}" = "--live" ]; then
    echo "  SKIP: mock-only trigger"
    ((PASS++)) || true
else
    OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"FAIL_CLOSED_PARAMS"}}' | "$PRE_HOOK" 2>/dev/null)
    assert_contains "Decision is deny" "$OUTPUT" '"deny"'
fi

echo ""
echo "--- PreToolUse: -32603 internal → exit 0 (fail-open, no deny) ---"
if [ "${1:-}" = "--live" ]; then
    echo "  SKIP: mock-only trigger"
    ((PASS++)) || true
else
    OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"FAIL_OPEN_INTERNAL"}}' | "$PRE_HOOK" 2>/dev/null)
    EXIT_CODE=$?
    assert_eq "Exit code is 0 (fail-open on -32603)" "0" "$EXIT_CODE"
    assert_empty "No output (no deny decision)" "$OUTPUT"
fi

echo ""
echo "--- PreToolUse: -32700 parse error → exit 0 (fail-open) ---"
if [ "${1:-}" = "--live" ]; then
    echo "  SKIP: mock-only trigger"
    ((PASS++)) || true
else
    OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"FAIL_OPEN_PARSE"}}' | "$PRE_HOOK" 2>/dev/null)
    assert_eq "Exit code is 0 (fail-open on -32700)" "0" "$?"
fi

echo ""
echo "--- PreToolUse: unknown error code → exit 0 (fail-open) ---"
if [ "${1:-}" = "--live" ]; then
    echo "  SKIP: mock-only trigger"
    ((PASS++)) || true
else
    OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"FAIL_OPEN_UNKNOWN"}}' | "$PRE_HOOK" 2>/dev/null)
    assert_eq "Exit code is 0 (fail-open on unknown code)" "0" "$?"
fi

echo ""
echo "--- PreToolUse: empty tool_name → allow ---"
OUTPUT=$(echo '{"tool_name":"","tool_input":{}}' | "$PRE_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Exit code is 0" "0" "$EXIT_CODE"
assert_empty "No output for empty tool" "$OUTPUT"

echo ""
echo "--- PreToolUse: no jq input → allow ---"
OUTPUT=$(echo '' | "$PRE_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Exit code is 0" "0" "$EXIT_CODE"

# ============================================================
# PostToolUse Hook Tests
# ============================================================

echo ""
echo "--- PostToolUse: clean output → silent ---"
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_response":{"stdout":"hi","exitCode":0}}' | "$POST_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Exit code is 0" "0" "$EXIT_CODE"
assert_empty "No output for clean result" "$OUTPUT"

echo ""
echo "--- PostToolUse: PII in output → context warning ---"
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"cat data"},"tool_response":{"stdout":"SSN: 123-45-6789","exitCode":0}}' | "$POST_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Exit code is 0" "0" "$EXIT_CODE"
if [ -n "$OUTPUT" ]; then
    assert_contains "Has PII warning" "$OUTPUT" "GOVERNANCE ALERT"
    assert_contains "Has redacted content" "$OUTPUT" "redacted"
else
    echo "  PASS: No PII warning (acceptable if scan returned no redaction)"
    ((PASS++)) || true
fi

echo ""
echo "--- PostToolUse: failed tool → still audits silently ---"
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"false"},"tool_response":{"stdout":"","stderr":"error","exitCode":1}}' | "$POST_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Exit code is 0 (never blocks)" "0" "$EXIT_CODE"

# ============================================================
# Telemetry Tests (v0.4.0)
# ============================================================

# Drain backgrounded children (version-check.sh + telemetry-ping.sh
# spawned by pre-tool-check.sh / post-tool-audit.sh in the test blocks
# above). Without this drain, the first telemetry test below races
# against a still-in-flight /health probe from the PreToolUse / PostToolUse
# hooks, and intermittently the foreground POST in this section times
# out (issue #85).
#
# Can't use bare `wait` — that would block on the mock server PID which
# never exits. Sleep covers the upper bound of background curls'
# timeouts (2s /health + 3s telemetry POST + buffer).
sleep 6

TELEMETRY_SCRIPT="$PLUGIN_DIR/scripts/telemetry-ping.sh"
ORIGINAL_HOME="$HOME"
ORIGINAL_AXONFLOW_TELEMETRY="${AXONFLOW_TELEMETRY:-}"

# Helper: create isolated HOME for telemetry tests.
#
# CRITICAL: Also forces AXONFLOW_CHECKPOINT_URL to the local mock port.
# Without this, any test that runs TELEMETRY_SCRIPT without its own
# explicit override would fire a REAL ping to checkpoint.getaxonflow.com
# — which shows up in prod digests as noise. Individual tests may still
# override AXONFLOW_CHECKPOINT_URL to test custom-URL behavior; just
# remember to re-export the mock URL (or call setup_telemetry_test
# again) afterward.
setup_telemetry_test() {
    TEST_HOME=$(mktemp -d)
    export HOME="$TEST_HOME"
    # Ensure the canonical opt-out env var is clear so we test the
    # telemetry-firing path. (DO_NOT_TRACK is no longer honored for
    # AxonFlow telemetry — it was dropped because host CLIs inject it.)
    unset AXONFLOW_TELEMETRY 2>/dev/null || true
    # Default every telemetry test to the local mock endpoint. No real
    # network fires unless a test explicitly unsets this and overrides.
    export AXONFLOW_CHECKPOINT_URL="http://127.0.0.1:$MOCK_PORT/v1/ping"
    # Clear any previous telemetry capture
    echo "" > "$TELEMETRY_CAPTURE_FILE" 2>/dev/null || true
}

teardown_telemetry_test() {
    export HOME="$ORIGINAL_HOME"
    unset AXONFLOW_CHECKPOINT_URL
    if [ -n "${ORIGINAL_AXONFLOW_TELEMETRY:-}" ]; then
        export AXONFLOW_TELEMETRY="$ORIGINAL_AXONFLOW_TELEMETRY"
    fi
    rm -rf "$TEST_HOME" 2>/dev/null || true
}

if [ "${1:-}" != "--live" ]; then

echo ""
echo "--- Telemetry: first invocation creates stamp file ---"
setup_telemetry_test
"$TELEMETRY_SCRIPT" 2>/dev/null
sleep 1
assert_file_exists "Stamp file created" "$TEST_HOME/.cache/axonflow/claude-code-plugin-telemetry-sent"
teardown_telemetry_test

echo ""
echo "--- Telemetry: subsequent invocation skips ---"
setup_telemetry_test
mkdir -p "$TEST_HOME/.cache/axonflow"
echo "existing-id" > "$TEST_HOME/.cache/axonflow/claude-code-plugin-telemetry-sent"
echo "" > "$TELEMETRY_CAPTURE_FILE"
"$TELEMETRY_SCRIPT" 2>/dev/null
sleep 1
CAPTURED=$(cat "$TELEMETRY_CAPTURE_FILE" 2>/dev/null || echo "")
CAPTURED_TRIMMED=$(echo "$CAPTURED" | tr -d '[:space:]')
assert_eq "No telemetry ping sent (stamp exists)" "" "$CAPTURED_TRIMMED"
teardown_telemetry_test

echo ""
echo "--- Telemetry: DO_NOT_TRACK=1 alone does NOT suppress (host CLI injects it) ---"
setup_telemetry_test
DO_NOT_TRACK=1 "$TELEMETRY_SCRIPT" 2>/dev/null
sleep 1
assert_file_exists "Stamp file created — DNT alone is not honored" "$TEST_HOME/.cache/axonflow/claude-code-plugin-telemetry-sent"
teardown_telemetry_test

echo ""
echo "--- Telemetry: AXONFLOW_TELEMETRY=off suppresses even with DO_NOT_TRACK=1 also set ---"
setup_telemetry_test
DO_NOT_TRACK=1 AXONFLOW_TELEMETRY=off "$TELEMETRY_SCRIPT" 2>/dev/null
sleep 1
assert_file_not_exists "AXONFLOW_TELEMETRY=off is the canonical opt-out and wins" "$TEST_HOME/.cache/axonflow/claude-code-plugin-telemetry-sent"
teardown_telemetry_test

echo ""
echo "--- Telemetry: AXONFLOW_TELEMETRY=off suppresses ---"
setup_telemetry_test
AXONFLOW_TELEMETRY=off "$TELEMETRY_SCRIPT" 2>/dev/null
sleep 1
assert_file_not_exists "No stamp file when opted out" "$TEST_HOME/.cache/axonflow/claude-code-plugin-telemetry-sent"
teardown_telemetry_test

echo ""
echo "--- Telemetry: failure does not block hook ---"
setup_telemetry_test
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | \
    AXONFLOW_CHECKPOINT_URL="http://127.0.0.1:19998/v1/ping" "$PRE_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Hook exits 0 despite telemetry failure" "0" "$EXIT_CODE"
teardown_telemetry_test

echo ""
echo "--- Telemetry: stamp directory auto-created ---"
setup_telemetry_test
# Ensure no .cache dir exists
rmdir "$TEST_HOME/.cache" 2>/dev/null || true
"$TELEMETRY_SCRIPT" 2>/dev/null
sleep 1
assert_file_exists "Stamp dir and file created" "$TEST_HOME/.cache/axonflow/claude-code-plugin-telemetry-sent"
teardown_telemetry_test

echo ""
echo "--- Telemetry: payload has required fields ---"
setup_telemetry_test
export AXONFLOW_CHECKPOINT_URL="http://127.0.0.1:$MOCK_PORT/v1/ping"
"$TELEMETRY_SCRIPT" 2>/dev/null
sleep 2
PAYLOAD=$(cat "$TELEMETRY_CAPTURE_FILE" 2>/dev/null || echo "{}")
assert_json_field "Has sdk field" "$PAYLOAD" "sdk"
assert_json_field "Has sdk_version field" "$PAYLOAD" "sdk_version"
assert_json_field "Has os field" "$PAYLOAD" "os"
assert_json_field "Has arch field" "$PAYLOAD" "arch"
assert_json_field "Has runtime_version field" "$PAYLOAD" "runtime_version"
assert_json_field "Has instance_id field" "$PAYLOAD" "instance_id"
unset AXONFLOW_CHECKPOINT_URL
teardown_telemetry_test

echo ""
echo "--- Telemetry: sdk field is claude-code-plugin ---"
setup_telemetry_test
export AXONFLOW_CHECKPOINT_URL="http://127.0.0.1:$MOCK_PORT/v1/ping"
"$TELEMETRY_SCRIPT" 2>/dev/null
sleep 2
PAYLOAD=$(cat "$TELEMETRY_CAPTURE_FILE" 2>/dev/null || echo "{}")
assert_json_field "sdk is claude-code-plugin" "$PAYLOAD" "sdk" "claude-code-plugin"
unset AXONFLOW_CHECKPOINT_URL
teardown_telemetry_test

echo ""
echo "--- Telemetry: custom AXONFLOW_CHECKPOINT_URL respected ---"
setup_telemetry_test
echo "" > "$TELEMETRY_CAPTURE_FILE"
export AXONFLOW_CHECKPOINT_URL="http://127.0.0.1:$MOCK_PORT/v1/ping"
"$TELEMETRY_SCRIPT" 2>/dev/null
sleep 2
PAYLOAD=$(cat "$TELEMETRY_CAPTURE_FILE" 2>/dev/null || echo "")
PAYLOAD_TRIMMED=$(echo "$PAYLOAD" | tr -d '[:space:]')
if [ -n "$PAYLOAD_TRIMMED" ]; then
    echo "  PASS: Custom URL received the ping"
    ((PASS++)) || true
else
    echo "  FAIL: Custom URL did not receive the ping"
    ((FAIL++)) || true
fi
unset AXONFLOW_CHECKPOINT_URL
teardown_telemetry_test

echo ""
echo "--- Telemetry: instance_id persists in stamp file ---"
setup_telemetry_test
export AXONFLOW_CHECKPOINT_URL="http://127.0.0.1:$MOCK_PORT/v1/ping"
"$TELEMETRY_SCRIPT" 2>/dev/null
sleep 1
STAMP_CONTENT=$(cat "$TEST_HOME/.cache/axonflow/claude-code-plugin-telemetry-sent" 2>/dev/null || echo "")
if echo "$STAMP_CONTENT" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    echo "  PASS: Stamp file contains UUID"
    ((PASS++)) || true
else
    echo "  FAIL: Stamp file does not contain valid UUID (got: '$STAMP_CONTENT')"
    ((FAIL++)) || true
fi
unset AXONFLOW_CHECKPOINT_URL
teardown_telemetry_test

fi  # end mock-only telemetry tests

# ============================================================
# UTF-8 Truncation Tests (v0.4.0)
# ============================================================

echo ""
echo "--- UTF-8: emoji in Write content does not corrupt ---"
OUTPUT=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test","content":"Hello world 🔥🔥🔥 test content"}}' | "$PRE_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Exit code is 0 with emoji content" "0" "$EXIT_CODE"

echo ""
echo "--- UTF-8: multi-byte chars at boundary preserved ---"
# Create content that is exactly 1999 ASCII chars + a multi-byte char
LONG_CONTENT=$(printf '%0.sa' $(seq 1 1999))
LONG_CONTENT="${LONG_CONTENT}€"
OUTPUT=$(echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test\",\"content\":\"${LONG_CONTENT}\"}}" | "$PRE_HOOK" 2>/dev/null)
EXIT_CODE=$?
assert_eq "Exit code is 0 with boundary multi-byte char" "0" "$EXIT_CODE"

# ============================================================
# Static Checks (v0.4.0)
# ============================================================

echo ""
echo "--- Static: post-tool-audit uses -sS consistently ---"
# Match 'curl -s ' but not 'curl -sS' — use regex: 'curl -s ' not followed by S
BARE_S_COUNT=$(grep -cE 'curl -s [^S]' "$PLUGIN_DIR/scripts/post-tool-audit.sh" || true)
SS_COUNT=$(grep -c 'curl -sS' "$PLUGIN_DIR/scripts/post-tool-audit.sh" || true)
assert_eq "No bare 'curl -s ' in post-tool-audit" "0" "$BARE_S_COUNT"
if [ "$SS_COUNT" -gt 0 ]; then
    echo "  PASS: post-tool-audit has $SS_COUNT 'curl -sS' calls"
    ((PASS++)) || true
else
    echo "  FAIL: post-tool-audit has no 'curl -sS' calls"
    ((FAIL++)) || true
fi

echo ""
echo "--- Static: hooks.json timeouts are all >= 15 ---"
MIN_TIMEOUT=$(jq '[.. | .timeout? // empty] | min' "$PLUGIN_DIR/hooks/hooks.json" 2>/dev/null || echo "0")
if [ "$MIN_TIMEOUT" -ge 15 ] 2>/dev/null; then
    echo "  PASS: Minimum hook timeout is $MIN_TIMEOUT (>= 15)"
    ((PASS++)) || true
else
    echo "  FAIL: Minimum hook timeout is $MIN_TIMEOUT (expected >= 15)"
    ((FAIL++)) || true
fi

# ============================================================
# Community-SaaS bootstrap: refusal on world-readable file
# ============================================================
#
# CHANGELOG promises: bootstrap "refuses to load a registration file with
# non-0600 permissions to prevent silent credential leak via a world-
# readable file." Regression-guard that promise here so a future refactor
# that drops the mode check trips this test.

echo ""
echo "--- Bootstrap: refuses to load 0644 registration file ---"
BOOTSTRAP_TEST_HOME=$(mktemp -d)
BOOTSTRAP_REGFILE="${BOOTSTRAP_TEST_HOME}/.config/axonflow/try-registration.json"
mkdir -p "$(dirname "$BOOTSTRAP_REGFILE")"
chmod 0700 "${BOOTSTRAP_TEST_HOME}/.config/axonflow"
# Encode the unsafe credential we want to verify is NOT loaded.
# base64(cs_unsafe:shouldnotload) is the value AXONFLOW_AUTH would take
# if the bootstrap ignored the world-readable file mode.
UNSAFE_AUTH=$(printf '%s' "cs_unsafe:shouldnotload" | base64 | tr -d '\n')
cat > "$BOOTSTRAP_REGFILE" <<'EOF'
{"tenant_id":"cs_unsafe","secret":"shouldnotload","expires_at":"2099-01-01T00:00:00Z"}
EOF
chmod 0644 "$BOOTSTRAP_REGFILE"

# Stub `curl` so the bootstrap's registration-fallback POST fails fast
# instead of hitting the real try.getaxonflow.com (which would issue a
# fresh tenant and populate AXONFLOW_AUTH from the new credentials,
# masking whether the 0644 refusal worked).
BOOTSTRAP_STUB_DIR=$(mktemp -d)
cat > "${BOOTSTRAP_STUB_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
# Test stub: emit no body, return HTTP 599 so the bootstrap treats it
# as a non-201 failure and leaves AXONFLOW_AUTH unset.
for arg in "$@"; do
  if [ "$arg" = "%{http_code}" ]; then
    echo "599"
    exit 0
  fi
done
exit 1
EOF
chmod +x "${BOOTSTRAP_STUB_DIR}/curl"

BOOTSTRAP_OUT=$(
  HOME="$BOOTSTRAP_TEST_HOME" \
  PATH="${BOOTSTRAP_STUB_DIR}:$PATH" \
  AXONFLOW_MODE="community-saas" \
  AXONFLOW_TELEMETRY=off \
  bash -c '. "'"$PLUGIN_DIR"'/scripts/community-saas-bootstrap.sh"; echo "AUTH=${AXONFLOW_AUTH:-}"' 2>&1
)

# The unsafe credential MUST NOT have been loaded into AXONFLOW_AUTH.
if echo "$BOOTSTRAP_OUT" | grep -q "AUTH=${UNSAFE_AUTH}"; then
    echo "  FAIL: bootstrap loaded the 0644 registration file's credential"
    ((FAIL++)) || true
else
    echo "  PASS: bootstrap did not load the world-readable credential"
    ((PASS++)) || true
fi
if echo "$BOOTSTRAP_OUT" | grep -q 'unsafe permissions'; then
    echo "  PASS: stderr warning emitted for unsafe permissions"
    ((PASS++)) || true
else
    echo "  FAIL: no stderr warning emitted for unsafe permissions"
    ((FAIL++)) || true
fi
rm -rf "$BOOTSTRAP_TEST_HOME" "$BOOTSTRAP_STUB_DIR"

# ============================================================
# Summary
# ============================================================

echo ""
echo "========================================"
echo " Results"
echo "========================================"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo "FAIL: $FAIL test(s) failed"
    exit 1
else
    echo "ALL $PASS tests passed"
fi
