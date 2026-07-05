#!/usr/bin/env bash
# Wire test for X-User-Email on the HOOK surfaces (issue #2754; identity-
# absent hardening #2836).
#
# Unlike test-user-identity.sh (helper unit) and test-mcp-headers.sh (the MCP
# headersHelper), this drives the ACTUAL hook scripts against a header-capturing
# mock agent and asserts the outbound requests carry X-User-Email when
# AXONFLOW_USER_EMAIL is set — and DON'T when it is unset (the real-world
# identity-absent fleet state: no env var, no git config, non-repo cwd), in
# which case the once-per-day stderr diagnostic must fire so an admin can see
# WHY attribution degraded. Covers the two hook surfaces the customer portal
# attribution depends on:
#   - pre-tool-check.sh  → check_policy  (PreToolUse)
#   - post-tool-audit.sh → check_output / audit_tool_call (PostToolUse)
#
# Stdlib-only (bash + python3 + jq).

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"
POST_HOOK="$PLUGIN_DIR/scripts/post-tool-audit.sh"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: python3/jq not on PATH"
  exit 0
fi

WORK="$(mktemp -d)"
CAP="$WORK/headers.log"    # one JSON object of request headers per line
: > "$CAP"
cleanup() { [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# Header-capturing mock agent. Appends each request's headers to $CAP and
# returns a minimal, valid MCP tools/call response so the hooks run to
# completion (allowed, no redaction).
cat > "$WORK/server.py" <<'PY'
import http.server, json, os, sys
CAP = os.environ["CAP_FILE"]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        _ = self.rfile.read(n) if n else b''
        with open(CAP, 'a') as f:
            f.write(json.dumps({k: v for k, v in self.headers.items()}) + "\n")
        result = {"allowed": True, "policies_evaluated": 0}
        body = {"jsonrpc":"2.0","id":"x","result":{"content":[{"type":"text","text":json.dumps(result)}]}}
        out = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)
server = http.server.HTTPServer(('127.0.0.1', 0), H)
sys.stdout.write(str(server.server_address[1]) + "\n"); sys.stdout.flush()
server.serve_forever()
PY

CAP_FILE="$CAP" python3 "$WORK/server.py" > "$WORK/port" 2>/dev/null &
SRV_PID=$!
# Wait for the port line.
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PORT="$(cat "$WORK/port" 2>/dev/null)"
if [ -z "$PORT" ]; then echo "FAIL: mock server did not start"; exit 1; fi

ENDPOINT="http://127.0.0.1:$PORT"

# run_hook <hook> <email-or-empty> — invokes a hook with a Write tool payload
# (so post-tool-audit's synchronous check_output scan fires) and gives any
# backgrounded audit curl a moment to flush.
#
# git config is neutralized (GIT_CONFIG_GLOBAL/SYSTEM=/dev/null) and the hook
# runs from a non-git dir so the git fallback is deterministically empty — this
# isolates the test to the AXONFLOW_USER_EMAIL env path. The "unset" cases thus
# assert "no identity available at all → no header", not "git happened to have
# one". (The git-fallback path itself is covered by test-user-identity.sh.)
#
# Each run gets a FRESH HOME (#2836): hermetic (no host ~/.config/axonflow
# credentials or ~/.cache stamps leak in) and it makes the identity-absent
# stderr diagnostic deterministic — the once-per-day stamp can never have been
# written yet. Hook stderr is captured to $HOOK_STDERR for assertion.
HOOK_STDERR="$WORK/hook-stderr.log"
RUN_N=0
run_hook() {
  local hook="$1" email="$2"
  RUN_N=$((RUN_N+1))
  local run_home="$WORK/home-$RUN_N"
  mkdir -p "$run_home"
  # session_id is always present in the hook stdin (Claude Code provides it) →
  # the hooks must emit X-Session-Id (#2753) regardless of the email path.
  local input='{"session_id":"sess-wire-123","tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt","content":"hello world"},"tool_response":{"success":true}}'
  if [ -n "$email" ]; then
    ( cd "$WORK" && echo "$input" | env HOME="$run_home" AXONFLOW_ENDPOINT="$ENDPOINT" AXONFLOW_AUTH="" \
        AXONFLOW_TELEMETRY=off GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        AXONFLOW_USER_EMAIL="$email" "$hook" >/dev/null 2>"$HOOK_STDERR" )
  else
    ( cd "$WORK" && echo "$input" | env -u AXONFLOW_USER_EMAIL HOME="$run_home" AXONFLOW_ENDPOINT="$ENDPOINT" AXONFLOW_AUTH="" \
        AXONFLOW_TELEMETRY=off GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$hook" >/dev/null 2>"$HOOK_STDERR" )
  fi
  sleep 0.4  # let any backgrounded audit curl flush to the capture log
}

# stderr_has_identity_diag — true if the captured hook stderr carries the
# identity-absent diagnostic (#2836).
stderr_has_identity_diag() {
  grep -q "No developer identity resolved" "$HOOK_STDERR" 2>/dev/null
}

# captured_has_email <email> — true if any captured request carried
# X-User-Email == email (header key match is case-insensitive on the wire, but
# the Python handler preserves the sent casing "X-User-Email").
captured_has_email() {
  local want="$1"
  jq -e --arg w "$want" 'select((."X-User-Email" // ."x-user-email") == $w)' "$CAP" >/dev/null 2>&1
}
captured_any_email() {
  jq -e 'select(has("X-User-Email") or has("x-user-email"))' "$CAP" >/dev/null 2>&1
}
# captured_has_session <sid> — true if any captured request carried
# X-Session-Id == sid (#2753).
captured_has_session() {
  local want="$1"
  jq -e --arg w "$want" 'select((."X-Session-Id" // ."x-session-id") == $w)' "$CAP" >/dev/null 2>&1
}

# --- pre-tool-check.sh with email set ---
: > "$CAP"
run_hook "$PRE_HOOK" "alice@example.com"
if captured_has_email "alice@example.com"; then
  pass "pre-tool-check.sh sends X-User-Email when AXONFLOW_USER_EMAIL set"
else
  fail "pre-tool-check.sh did not send X-User-Email: $(cat "$CAP")"
fi
if captured_has_session "sess-wire-123"; then
  pass "pre-tool-check.sh sends X-Session-Id from hook stdin session_id"
else
  fail "pre-tool-check.sh did not send X-Session-Id: $(cat "$CAP")"
fi
if stderr_has_identity_diag; then
  fail "pre-tool-check.sh fired the identity diagnostic despite an identity being set"
else
  pass "pre-tool-check.sh stays silent about identity when AXONFLOW_USER_EMAIL is set"
fi

# --- pre-tool-check.sh with NO email (identity-ABSENT: no env, no git config,
# non-repo cwd) → header absent + stderr diagnostic fires (#2836) ---
: > "$CAP"
run_hook "$PRE_HOOK" ""
if captured_any_email; then
  fail "pre-tool-check.sh sent X-User-Email with no identity: $(cat "$CAP")"
else
  pass "pre-tool-check.sh omits X-User-Email when unset"
fi
if stderr_has_identity_diag; then
  pass "pre-tool-check.sh fires the identity-absent stderr diagnostic"
else
  fail "pre-tool-check.sh identity-absent diagnostic missing: $(cat "$HOOK_STDERR" 2>/dev/null)"
fi

# --- post-tool-audit.sh with email set ---
: > "$CAP"
run_hook "$POST_HOOK" "carol@example.com"
if captured_has_email "carol@example.com"; then
  pass "post-tool-audit.sh sends X-User-Email when AXONFLOW_USER_EMAIL set"
else
  fail "post-tool-audit.sh did not send X-User-Email: $(cat "$CAP")"
fi
if captured_has_session "sess-wire-123"; then
  pass "post-tool-audit.sh sends X-Session-Id from hook stdin session_id"
else
  fail "post-tool-audit.sh did not send X-Session-Id: $(cat "$CAP")"
fi
if stderr_has_identity_diag; then
  fail "post-tool-audit.sh fired the identity diagnostic despite an identity being set"
else
  pass "post-tool-audit.sh stays silent about identity when AXONFLOW_USER_EMAIL is set"
fi

# --- post-tool-audit.sh with NO email (identity-ABSENT) → header absent +
# stderr diagnostic fires (#2836) ---
: > "$CAP"
run_hook "$POST_HOOK" ""
if captured_any_email; then
  fail "post-tool-audit.sh sent X-User-Email with no identity: $(cat "$CAP")"
else
  pass "post-tool-audit.sh omits X-User-Email when unset"
fi
if stderr_has_identity_diag; then
  pass "post-tool-audit.sh fires the identity-absent stderr diagnostic"
else
  fail "post-tool-audit.sh identity-absent diagnostic missing: $(cat "$HOOK_STDERR" 2>/dev/null)"
fi

echo ""
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
