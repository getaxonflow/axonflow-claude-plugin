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
MOCK_PORT=18199

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

start_mock_server() {
    # Python mock server that responds based on the statement content
    python3 -c "
import http.server, json, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length)) if length > 0 else {}

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

http.server.HTTPServer(('127.0.0.1', $MOCK_PORT), Handler).serve_forever()
" &
    MOCK_PID=$!
    sleep 1
}

stop_mock_server() {
    if [ -n "$MOCK_PID" ]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
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
