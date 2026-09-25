#!/usr/bin/env bash
# Mode-clarity gate (ADR-048 D3) — REQUIRED CI check on every plugin PR.
#
# Asserts that pre-tool-check.sh:
#   1. Emits the canary "[AxonFlow] Connected to AxonFlow at <URL> (mode=<X>)"
#      on stderr (NOT stdout — stdout is the hook protocol).
#   2. Stdout is silent of any [AxonFlow] markers (protocol cleanliness).
#   3. The URL in the canary parses cleanly to the expected scheme+host+port,
#      via parsed-URL comparison (defends against
#      "log says localhost, requests go to SaaS" via lookalike domain).
#
# Runs each scenario in a sandboxed HOME so the disclosure-stamp / telemetry-
# stamp / registration-file state from one scenario can't bleed into another.
#
# NEVER REACHES PRODUCTION. The "no-config" scenario runs the hook with no
# endpoint and no credential, so it enters community-saas mode and its
# registration bootstrap POSTs /api/v1/register before stdin is read. Without
# a redirect that request went to production https://try.getaxonflow.com on
# every run of this gate (axonflow-enterprise#4249, comment 5694502320). Every
# scenario now runs with:
#   - the bootstrap's test override (AXONFLOW_HARNESS=1 and
#     AXONFLOW_HARNESS_REGISTER_URL) pointed at a local listener that records
#     each request and answers 503, so no registration is written; the canary
#     still names https://try.getaxonflow.com, which is what this gate asserts;
#   - a curl wrapper first on PATH that refuses any URL whose host is not
#     127.0.0.1 or localhost, and logs it. Any refused URL fails the gate, and
#     the no-config scenario must have reached the listener. With the redirect
#     removed, the no-config scenario fails at its first check, the refused
#     URL (https://try.getaxonflow.com/api/v1/register), with nothing sent.
#
# Exit 0 on all-pass; non-zero on any mismatch.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRE_TOOL="${PLUGIN_DIR}/scripts/pre-tool-check.sh"

if [ ! -x "$PRE_TOOL" ]; then
  echo "FAIL: pre-tool-check.sh not found or not executable at $PRE_TOOL" >&2
  exit 1
fi

WORK_DIR=$(mktemp -d)
LISTENER_LOG="$WORK_DIR/listener.log"
REFUSED_LOG="$WORK_DIR/refused.log"
: >"$LISTENER_LOG"
: >"$REFUSED_LOG"
LISTENER_PID=""
cleanup() {
  if [ -n "$LISTENER_PID" ]; then kill "$LISTENER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# The local listener: records "<METHOD> <path>" per request, answers 503.
python3 -c '
import http.server, sys
log, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def _rec(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n: self.rfile.read(n)
        with open(log, "a") as f: f.write(self.command + " " + self.path + "\n")
        self.send_response(503); self.end_headers()
    do_GET = do_POST = _rec
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
' "$LISTENER_LOG" "$WORK_DIR/port" &
LISTENER_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK_DIR/port" ] && break; sleep 0.1; done
LISTENER_PORT=$(cat "$WORK_DIR/port" 2>/dev/null || true)
if [ -z "$LISTENER_PORT" ]; then
  echo "FAIL: the local registration listener did not start" >&2
  exit 1
fi

# The curl wrapper: loopback URLs pass to the real curl; anything else is
# logged and refused (exit 7, as curl's "failed to connect").
REAL_CURL=$(command -v curl)
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    http://127.0.0.1:*|http://127.0.0.1/*|http://localhost:*|http://localhost/*) ;;
    http://*|https://*) echo "\$a" >>"$REFUSED_LOG"; exit 7 ;;
  esac
done
exec "$REAL_CURL" "\$@"
SHIM
chmod +x "$WORK_DIR/bin/curl"
HARNESS_ENV="AXONFLOW_HARNESS=1 AXONFLOW_HARNESS_REGISTER_URL=http://127.0.0.1:${LISTENER_PORT}/api/v1/register"

# Each scenario: name, env vars to export, expected URL, expected mode.
# Parallel arrays (older bash on macOS doesn't have associative arrays).
SCENARIO_NAMES=(
  "no-config"
  "explicit-localhost"
  "explicit-endpoint-no-auth"
  "explicit-auth-no-endpoint"
  "both-set"
)
SCENARIO_ENVS=(
  ""
  "AXONFLOW_ENDPOINT=http://localhost:8080"
  "AXONFLOW_ENDPOINT=http://my-self-host:9000"
  "AXONFLOW_AUTH=Y3M6c2VjcmV0"
  "AXONFLOW_ENDPOINT=http://my-self-host:9000 AXONFLOW_AUTH=Y3M6c2VjcmV0"
)
EXPECTED_URLS=(
  "https://try.getaxonflow.com"
  "http://localhost:8080"
  "http://my-self-host:9000"
  "http://localhost:8080"
  "http://my-self-host:9000"
)
EXPECTED_MODES=(
  "community-saas"
  "self-hosted"
  "self-hosted"
  "self-hosted"
  "self-hosted"
)

# Anti-spoof URL parser. Compare scheme + host + port, not substring —
# `https://try.getaxonflow.com.attacker.com/` would pass a naive grep.
parse_url_host() {
  local url="$1"
  python3 -c "
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1])
print(f'{u.scheme}://{u.hostname}:{u.port or 0}')
" "$url"
}

run_scenario() {
  local name="$1" env_str="$2" expected_url="$3" expected_mode="$4"
  local sandbox stdout_file stderr_file rc=0

  sandbox=$(mktemp -d)
  trap "rm -rf '$sandbox'" RETURN
  stdout_file="${sandbox}/stdout"
  stderr_file="${sandbox}/stderr"

  # Sandbox HOME so cross-scenario stamp/registration state can't bleed.
  # PATH keeps jq/flock available, with the loopback-only curl wrapper first.
  # AXONFLOW_TELEMETRY=off silences the heartbeat ping and
  # AXONFLOW_PLUGIN_VERSION_CHECK=off the backgrounded /health probe (to the
  # scenario's endpoint, a placeholder host here), so we're testing only the
  # hook canary path and nothing runs after the scenario returns. HARNESS_ENV points the registration bootstrap at the
  # local listener (see the header).
  local listener_before refused_before
  listener_before=$(wc -l <"$LISTENER_LOG" | tr -d ' ')
  refused_before=$(wc -l <"$REFUSED_LOG" | tr -d ' ')
  # shellcheck disable=SC2086
  env -i \
    HOME="$sandbox" \
    PATH="$WORK_DIR/bin:$PATH" \
    AXONFLOW_TELEMETRY=off \
    AXONFLOW_PLUGIN_VERSION_CHECK=off \
    $HARNESS_ENV \
    $env_str \
    bash "$PRE_TOOL" </dev/null >"$stdout_file" 2>"$stderr_file" || rc=$?

  # Assertion 0: nothing left this machine. A refused URL is a request the
  # hook tried to send somewhere other than loopback.
  if [ "$(wc -l <"$REFUSED_LOG" | tr -d ' ')" != "$refused_before" ]; then
    echo "FAIL [$name]: the hook tried to reach a non-loopback URL:" >&2
    tail -n +"$((refused_before + 1))" "$REFUSED_LOG" >&2
    return 1
  fi
  # The community-saas scenario's registration reached the local listener,
  # which proves the redirect is in force; a self-hosted scenario registers
  # nothing.
  local listener_after
  listener_after=$(wc -l <"$LISTENER_LOG" | tr -d ' ')
  if [ "$expected_mode" = "community-saas" ]; then
    if ! grep -q '^POST /api/v1/register$' <(tail -n +"$((listener_before + 1))" "$LISTENER_LOG"); then
      echo "FAIL [$name]: the registration did not reach the local listener (is the redirect in force?)" >&2
      return 1
    fi
  elif [ "$listener_after" != "$listener_before" ]; then
    echo "FAIL [$name]: a self-hosted scenario sent a registration request" >&2
    return 1
  fi

  # Assertion 1: stderr contains exactly one canary line.
  local canary_count
  canary_count=$(grep -c "^\[AxonFlow\] Connected to AxonFlow at" "$stderr_file" || true)
  if [ "$canary_count" -ne 1 ]; then
    echo "FAIL [$name]: expected exactly 1 canary line on stderr, got $canary_count" >&2
    cat "$stderr_file" >&2
    return 1
  fi

  local canary_line
  canary_line=$(grep "^\[AxonFlow\] Connected to AxonFlow at" "$stderr_file")
  local actual_url actual_mode
  actual_url=$(printf '%s\n' "$canary_line" | sed -E 's|^\[AxonFlow\] Connected to AxonFlow at ([^ ]+) .*$|\1|')
  actual_mode=$(printf '%s\n' "$canary_line" | sed -E 's|^.*\(mode=([^)]+)\)$|\1|')

  # Anti-spoof: compare parsed URL components.
  local actual_parsed expected_parsed
  actual_parsed=$(parse_url_host "$actual_url" 2>/dev/null || echo "")
  expected_parsed=$(parse_url_host "$expected_url" 2>/dev/null || echo "")
  if [ "$actual_parsed" != "$expected_parsed" ] || [ -z "$actual_parsed" ]; then
    echo "FAIL [$name]: URL mismatch. canary=$actual_url ($actual_parsed), expected=$expected_url ($expected_parsed)" >&2
    return 1
  fi

  if [ "$actual_mode" != "$expected_mode" ]; then
    echo "FAIL [$name]: mode mismatch. canary mode=$actual_mode, expected=$expected_mode" >&2
    return 1
  fi

  # Assertion 2: stdout MUST NOT contain any [AxonFlow] markers. A canary
  # leaking onto stdout would corrupt the JSON response Claude Code expects.
  if grep -q '\[AxonFlow\]' "$stdout_file"; then
    echo "FAIL [$name]: [AxonFlow] marker leaked onto stdout" >&2
    cat "$stdout_file" >&2
    return 1
  fi

  echo "PASS [$name]: $expected_url ($expected_mode)"
  return 0
}

PASSED=0
FAILED=0
for i in "${!SCENARIO_NAMES[@]}"; do
  if run_scenario "${SCENARIO_NAMES[$i]}" "${SCENARIO_ENVS[$i]}" "${EXPECTED_URLS[$i]}" "${EXPECTED_MODES[$i]}"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "mode-clarity: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
