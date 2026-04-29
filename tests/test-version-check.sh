#!/usr/bin/env bash
# Regression tests for scripts/version-check.sh.
#
# Spawns a tiny stub HTTP server that returns a configurable /health body,
# runs version-check.sh against it with a clean HOME (so the stamp-file
# guard always lets the check fire), and asserts the script behaves
# correctly across:
#
#   - Below min: warn-line on stderr, stamp written, exit 0
#   - Between min and recommended: info-line on stderr, stamp written
#   - At or above recommended: silent, stamp written
#   - Older platform without plugin_compatibility: silent, stamp written
#   - Platform unreachable: silent, stamp NOT written (retry next time)
#   - Missing per-plugin entry: silent, stamp written
#   - AXONFLOW_PLUGIN_VERSION_CHECK=off: silent, stamp NOT written
#   - Stamp already exists: silent, exits early
#
# Run locally:
#   bash tests/test-version-check.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_SCRIPT="$PLUGIN_DIR/scripts/version-check.sh"
PLUGIN_ID="claude"

if [ ! -x "$CHECK_SCRIPT" ]; then
  echo "FAIL: $CHECK_SCRIPT not executable"
  exit 1
fi

# Spawn a stub HTTP server. /health responds with whatever JSON is
# currently in $HEALTH_BODY_FILE; non-/health 404s.
HEALTH_BODY_FILE="$(mktemp)"
PYTHON="$(command -v python3 || command -v python)"
if [ -z "$PYTHON" ]; then
  echo "skip: python not available — version-check tests need a stub server"
  exit 0
fi

STUB_PORT=$((RANDOM + 30000))
"$PYTHON" - "$STUB_PORT" "$HEALTH_BODY_FILE" >/dev/null 2>&1 &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null || true; rm -f "$HEALTH_BODY_FILE"' EXIT

# Inline stub
"$PYTHON" -c "
import http.server, socketserver, sys
port = int(sys.argv[1])
body_file = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/health':
            self.send_response(404); self.end_headers(); return
        try:
            with open(body_file) as f: body = f.read().strip()
        except OSError:
            body = ''
        if not body:
            self.send_response(503); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a, **k): pass
with socketserver.TCPServer(('127.0.0.1', port), H) as srv:
    srv.serve_forever()
" "$STUB_PORT" "$HEALTH_BODY_FILE" >/dev/null 2>&1 &
STUB_PID=$!

# Wait up to 3s for the stub to bind
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  curl -s --max-time 1 "http://127.0.0.1:${STUB_PORT}/health" >/dev/null 2>&1 && break
  sleep 0.25
done

PASS_COUNT=0
FAIL_COUNT=0
ASSERT() {
  local label="$1"
  local expected_pattern="$2"
  local actual="$3"
  if echo "$actual" | grep -qE "$expected_pattern"; then
    echo "  pass: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: $label"
    echo "    expected match for: $expected_pattern"
    echo "    actual: $actual"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

run_check() {
  local fake_home
  fake_home="$(mktemp -d)"
  local stderr_file
  stderr_file="$(mktemp)"
  HOME="$fake_home" \
    AXONFLOW_ENDPOINT="http://127.0.0.1:${STUB_PORT}" \
    "$CHECK_SCRIPT" 2>"$stderr_file"
  local rc=$?
  local stamp_exists="no"
  if [ -f "$fake_home/.cache/axonflow/claude-plugin-version-check-stamp" ]; then
    stamp_exists="yes"
  fi
  cat "$stderr_file"
  echo "EXIT=$rc"
  echo "STAMP=$stamp_exists"
  rm -rf "$fake_home" "$stderr_file"
}

set_health_body() {
  printf '%s' "$1" > "$HEALTH_BODY_FILE"
}

# ---- Test 1: below min → warn ----
echo "Test 1: plugin below min → warn"
set_health_body "{\"plugin_compatibility\":{\"min_plugin_version\":{\"$PLUGIN_ID\":\"99.0.0\"},\"recommended_plugin_version\":{\"$PLUGIN_ID\":\"99.0.0\"}}}"
out=$(run_check)
ASSERT "exits 0"           "EXIT=0"                          "$out"
ASSERT "warns on stderr"   "below the platform's minimum"    "$out"
ASSERT "stamp written"     "STAMP=yes"                       "$out"

# ---- Test 2: between min and recommended → info ----
echo "Test 2: between min and recommended → info"
set_health_body "{\"plugin_compatibility\":{\"min_plugin_version\":{\"$PLUGIN_ID\":\"0.0.1\"},\"recommended_plugin_version\":{\"$PLUGIN_ID\":\"99.0.0\"}}}"
out=$(run_check)
ASSERT "exits 0"           "EXIT=0"                          "$out"
ASSERT "info on stderr"    "below the recommended"           "$out"
ASSERT "stamp written"     "STAMP=yes"                       "$out"

# ---- Test 3: at or above recommended → silent ----
echo "Test 3: at or above recommended → silent"
set_health_body "{\"plugin_compatibility\":{\"min_plugin_version\":{\"$PLUGIN_ID\":\"0.0.1\"},\"recommended_plugin_version\":{\"$PLUGIN_ID\":\"0.0.1\"}}}"
out=$(run_check)
ASSERT "exits 0"           "EXIT=0"                          "$out"
ASSERT "no stderr output"  "^EXIT=0"                         "$(echo "$out" | grep -v '^STAMP=' | head -1)"
ASSERT "stamp written"     "STAMP=yes"                       "$out"

# ---- Test 4: older platform without plugin_compatibility → silent ----
echo "Test 4: older platform → silent"
set_health_body '{"status":"healthy"}'
out=$(run_check)
ASSERT "exits 0"           "EXIT=0"                          "$out"
ASSERT "stamp written"     "STAMP=yes"                       "$out"

# ---- Test 5: missing per-plugin entry → silent ----
echo "Test 5: missing per-plugin entry → silent"
set_health_body '{"plugin_compatibility":{"min_plugin_version":{"openclaw":"1.0.0"},"recommended_plugin_version":{"openclaw":"1.0.0"}}}'
out=$(run_check)
ASSERT "exits 0"           "EXIT=0"                          "$out"
ASSERT "stamp written"     "STAMP=yes"                       "$out"

# ---- Test 6: platform unreachable → silent, no stamp ----
echo "Test 6: platform unreachable → silent, no stamp"
fake_home="$(mktemp -d)"
stderr_file="$(mktemp)"
HOME="$fake_home" \
  AXONFLOW_ENDPOINT="http://127.0.0.1:1" \
  "$CHECK_SCRIPT" 2>"$stderr_file" || true
out=$(cat "$stderr_file")
stamp_exists="no"
[ -f "$fake_home/.cache/axonflow/claude-plugin-version-check-stamp" ] && stamp_exists="yes"
ASSERT "no stderr"         "^$"                              "$out"
ASSERT "no stamp written"  "^no$"                            "$stamp_exists"
rm -rf "$fake_home" "$stderr_file"

# ---- Test 7: AXONFLOW_PLUGIN_VERSION_CHECK=off → silent, no stamp ----
echo "Test 7: opt-out env var"
set_health_body "{\"plugin_compatibility\":{\"min_plugin_version\":{\"$PLUGIN_ID\":\"99.0.0\"}}}"
fake_home="$(mktemp -d)"
stderr_file="$(mktemp)"
HOME="$fake_home" \
  AXONFLOW_ENDPOINT="http://127.0.0.1:${STUB_PORT}" \
  AXONFLOW_PLUGIN_VERSION_CHECK=off \
  "$CHECK_SCRIPT" 2>"$stderr_file"
stamp_exists="no"
[ -f "$fake_home/.cache/axonflow/claude-plugin-version-check-stamp" ] && stamp_exists="yes"
out=$(cat "$stderr_file")
ASSERT "no stderr"         "^$"                              "$out"
ASSERT "no stamp written"  "^no$"                            "$stamp_exists"
rm -rf "$fake_home" "$stderr_file"

# ---- Test 8: stamp already exists → exits early, no curl ----
echo "Test 8: stamp guard"
set_health_body "{\"plugin_compatibility\":{\"min_plugin_version\":{\"$PLUGIN_ID\":\"99.0.0\"}}}"
fake_home="$(mktemp -d)"
mkdir -p "$fake_home/.cache/axonflow"
touch "$fake_home/.cache/axonflow/claude-plugin-version-check-stamp"
stderr_file="$(mktemp)"
HOME="$fake_home" \
  AXONFLOW_ENDPOINT="http://127.0.0.1:${STUB_PORT}" \
  "$CHECK_SCRIPT" 2>"$stderr_file"
out=$(cat "$stderr_file")
ASSERT "no stderr"         "^$"                              "$out"
rm -rf "$fake_home" "$stderr_file"

echo
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
