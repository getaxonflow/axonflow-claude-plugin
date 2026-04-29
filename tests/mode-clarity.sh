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
# Exit 0 on all-pass; non-zero on any mismatch.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRE_TOOL="${PLUGIN_DIR}/scripts/pre-tool-check.sh"

if [ ! -x "$PRE_TOOL" ]; then
  echo "FAIL: pre-tool-check.sh not found or not executable at $PRE_TOOL" >&2
  exit 1
fi

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
  # PATH preserved so curl/jq/flock remain available. AXONFLOW_TELEMETRY=off
  # silences the heartbeat ping so we're testing only the hook canary path.
  env -i \
    HOME="$sandbox" \
    PATH="$PATH" \
    AXONFLOW_TELEMETRY=off \
    $env_str \
    bash "$PRE_TOOL" </dev/null >"$stdout_file" 2>"$stderr_file" || rc=$?

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
