#!/usr/bin/env bash
# Runtime proof for the v1 telemetry-schema heartbeat payload (#2008).
#
# The plugin's anonymous heartbeat now carries four v1-schema fields:
# telemetry_type, deployment_mode, endpoint_type, profile. The
# canonical wire-shape proof for these lives at
# tests/heartbeat-real-stack/run_real_stack.sh — that harness drives
# the public pre-tool-check.sh hook against a Python fake checkpoint
# server bound to 127.0.0.1, captures the actual ping payload off the
# wire, and asserts the four field contracts.
#
# This runtime-e2e/ wrapper exists so the definition-of-done.yml
# mechanical gate (which only inspects runtime-e2e/) sees the runtime
# proof for this PR. It runs the same harness — no mocks, no stubs.
#
# Exit codes:
#   0   PASS — all 15 cold-start + warm-cache assertions pass
#   1   FAIL — any assertion failed
#   0   SKIP — required tools missing (bash, jq, curl, python3)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="$PLUGIN_DIR/tests/heartbeat-real-stack/run_real_stack.sh"

for tool in bash jq curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not on PATH"
    exit 0
  fi
done

if [ ! -f "$HARNESS" ]; then
  echo "FAIL: harness missing at $HARNESS"
  exit 1
fi

echo "==> Running heartbeat-real-stack harness against v1 telemetry payload"
( cd "$PLUGIN_DIR" && bash "$HARNESS" )
RC=$?

if [ $RC -eq 0 ]; then
  echo "PASS: v1 telemetry-schema fields verified on the wire"
  exit 0
fi

echo "FAIL: heartbeat-real-stack harness reported assertion failures (rc=$RC)"
exit 1
