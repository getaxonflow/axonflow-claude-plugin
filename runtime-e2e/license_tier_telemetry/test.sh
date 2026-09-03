#!/usr/bin/env bash
# Runtime proof for license_tier on the heartbeat (#3619).
#
# Two stages, and both run the plugin's ACTUAL shipped shell — no reimplementation
# of the payload, no reimplementation of the probe.
#
#   Stage 1 (always) — the behaviour matrix plus its mutation gate. Every tier
#   value round-trips verbatim; every probe failure omits the key and leaves the
#   heartbeat intact. The gate then plants a defect in a copy of the shipped
#   script for each of those properties and requires the matrix to go red, so a
#   green stage 1 is evidence rather than decoration.
#
#   Stage 2 (when a real AxonFlow agent is reachable) — the honest end of the
#   claim. Reads the tier a REAL running agent reports about itself at /health,
#   drives the real heartbeat against that same agent, and requires the captured
#   ping to carry that exact value. Nothing in this stage knows what the tier
#   ought to be; it is read from the agent at runtime, so the assertion holds for
#   a community stack and an enterprise-licensed one alike.
#
# Stage 2 is skipped when no agent is reachable, which is the norm on CI runners.
# It is never the only evidence: stage 1 covers the same property deterministically.
#
# Run:
#   ./runtime-e2e/license_tier_telemetry/test.sh
#   AXONFLOW_ENDPOINT=http://localhost:8080 ./runtime-e2e/license_tier_telemetry/test.sh
#
# Exit: 0 PASS · 1 FAIL · 0 + SKIP line when required tools are absent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MATRIX="$PLUGIN_DIR/tests/telemetry-license-tier/run.sh"
GATE="$PLUGIN_DIR/tests/telemetry-license-tier/mutation_gate.sh"

for tool in bash jq curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not on PATH"
    exit 0
  fi
done

for f in "$MATRIX" "$GATE"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: harness missing at $f" >&2
    exit 1
  fi
done

RC=0

echo "==> Stage 1a: license_tier behaviour matrix against the shipped telemetry-ping.sh"
if bash "$MATRIX"; then
  echo "PASS: matrix green"
else
  echo "FAIL: matrix reported assertion failures" >&2
  RC=1
fi

echo ""
echo "==> Stage 1b: mutation gate — the matrix must be able to go red"
if bash "$GATE"; then
  echo "PASS: every planted defect was caught, and the neutral control survived"
else
  echo "FAIL: mutation gate reported a survivor or killed the control" >&2
  RC=1
fi

# ---------------------------------------------------------------------------
# Stage 2 — real agent.
# ---------------------------------------------------------------------------
echo ""
echo "==> Stage 2: verbatim round-trip from a real AxonFlow agent"

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"

HEALTH=$(curl -sS --fail --max-time 5 "${AXONFLOW_ENDPOINT}/health" 2>/dev/null || printf '')
if [ -z "$HEALTH" ]; then
  echo "SKIP: no AxonFlow agent reachable at ${AXONFLOW_ENDPOINT}/health"
  echo "      Start one via axonflow-enterprise scripts/setup-e2e-testing.sh to run this stage."
  exit "$RC"
fi

AGENT_TIER=$(printf '%s' "$HEALTH" | jq -r 'if type == "object" and (.tier | type) == "string" then .tier else empty end' 2>/dev/null || printf '')
if [ -z "$AGENT_TIER" ]; then
  # An agent that reports no tier is a real deployment shape, not a failure:
  # the contract in that case is that the key is omitted. Assert THAT instead
  # of skipping, so an older agent still exercises the fail-open path.
  echo "    agent at ${AXONFLOW_ENDPOINT} reports no string tier — asserting the key is omitted"
  EXPECT_ABSENT=1
else
  echo "    agent at ${AXONFLOW_ENDPOINT} reports tier=${AGENT_TIER}"
  EXPECT_ABSENT=0
fi

WORK=$(mktemp -d)
SANDBOX_HOME=$(mktemp -d)
RECV_PID=""
cleanup() {
  [ -n "$RECV_PID" ] && kill "$RECV_PID" 2>/dev/null
  rm -rf "$WORK" "$SANDBOX_HOME"
}
trap cleanup EXIT

# The heartbeat's destination is redirected to a local receiver so a test run
# never writes a row into production analytics. The agent under test — the
# thing whose tier is being proven — is the real one at AXONFLOW_ENDPOINT.
RECV_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
PYTHONUNBUFFERED=1 python3 "$PLUGIN_DIR/tests/telemetry-license-tier/health_server.py" "$RECV_PORT" "$WORK" >"$WORK/_recv.out" 2>&1 &
RECV_PID=$!

deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ -f "$WORK/_server_ready" ] && break
  sleep 0.1
done
if [ ! -f "$WORK/_server_ready" ]; then
  echo "FAIL: local ping receiver did not start within 30s" >&2
  cat "$WORK/_recv.out" >&2 || true
  exit 1
fi

env -i \
  HOME="$SANDBOX_HOME" \
  PATH="$PATH" \
  AXONFLOW_TELEMETRY="" \
  AXONFLOW_CHECKPOINT_URL="http://127.0.0.1:${RECV_PORT}/v1/ping" \
  AXONFLOW_HARNESS=1 \
  AXONFLOW_HARNESS_AGENT_ENDPOINT="$AXONFLOW_ENDPOINT" \
  bash "$PLUGIN_DIR/scripts/telemetry-ping.sh"
PING_RC=$?

if [ "$PING_RC" -ne 0 ]; then
  echo "FAIL: telemetry-ping.sh exited $PING_RC against the real agent (must always be 0)" >&2
  RC=1
fi

PING=$(head -1 "$WORK/_pings.jsonl" 2>/dev/null)
if [ -z "$PING" ]; then
  echo "FAIL: no heartbeat captured against the real agent" >&2
  exit 1
fi

# Presence is asked of jq directly, never encoded into a sentinel string. A
# sentinel is a value the SERVER can also send: a platform answering
# `"tier":"__ABSENT__"` would make a present key indistinguishable from a
# missing one, in the very comparison whose job is telling those apart.
ping_has() { printf '%s' "$PING" | jq -e --arg k "$1" 'has($k)' >/dev/null 2>&1; }
ping_get() { printf '%s' "$PING" | jq -r --arg k "$1" '.[$k] | tostring'; }
# Only for MESSAGES - never compared against.
ping_show() { if ping_has "$1"; then ping_get "$1"; else printf '(absent)'; fi; }

GOT=$(ping_show license_tier)

if [ "$EXPECT_ABSENT" = "1" ]; then
  if ! ping_has license_tier; then
    echo "PASS: agent reports no tier and the heartbeat omits license_tier"
  else
    echo "FAIL: agent reports no tier but the heartbeat carried license_tier=$GOT" >&2
    RC=1
  fi
elif ping_has license_tier && [ "$(ping_get license_tier)" = "$AGENT_TIER" ]; then
  echo "PASS: heartbeat license_tier=$GOT matches the tier the live agent reports, verbatim"
else
  echo "FAIL: heartbeat license_tier=$GOT but the live agent reports $AGENT_TIER" >&2
  RC=1
fi

# The two members enterprise#3662 adds to /health, asserted against whatever
# THIS agent actually reports. Nothing here knows which answer is correct: the
# expectation is read from the live /health at run time, so the same assertion
# holds against a platform that carries them and one that predates them.
for member in edition deployment_mode; do
  case "$member" in
    edition)         ping_field="edition" ;;
    deployment_mode) ping_field="platform_deployment_mode" ;;
  esac
  agent_value=$(printf '%s' "$HEALTH" | jq -r --arg k "$member" \
    'if type == "object" and (.[$k] | type) == "string" then .[$k] else empty end' 2>/dev/null || printf '')
  ping_value=$(ping_show "$ping_field")
  if [ -z "$agent_value" ]; then
    if ! ping_has "$ping_field"; then
      echo "PASS: agent reports no $member and the heartbeat omits $ping_field"
    else
      echo "FAIL: agent reports no $member but the heartbeat carried $ping_field=$ping_value" >&2
      RC=1
    fi
  elif ping_has "$ping_field" && [ "$(ping_get "$ping_field")" = "$agent_value" ]; then
    echo "PASS: heartbeat $ping_field=$ping_value matches the live agent, verbatim"
  else
    echo "FAIL: heartbeat $ping_field=$ping_value but the live agent reports $agent_value" >&2
    RC=1
  fi
done

# The same run must also prove the dimensions stay separate against a real
# platform, not only against a scripted one.
DM=$(printf '%s' "$PING" | jq -r '.deployment_mode')
if ! ping_has license_tier || [ "$(ping_get license_tier)" != "$DM" ]; then
  echo "PASS: license_tier ($GOT) and deployment_mode ($DM) reported as separate dimensions"
else
  echo "FAIL: license_tier and deployment_mode both read $GOT — conflated" >&2
  RC=1
fi

# platform_deployment_mode, when the live agent reports one, describes the
# PLATFORM; deployment_mode describes where this plugin is pointed. They may
# legitimately coincide on some deployments, so this asserts only that the
# local classification was not REPLACED by the platform's answer.
PDM=$(ping_show platform_deployment_mode)
LOCAL_EXPECTED=$(printf '%s' "$AXONFLOW_ENDPOINT" | grep -qE 'try\.getaxonflow\.com' && printf 'community_saas' || printf 'self_hosted')
if [ "$DM" = "$LOCAL_EXPECTED" ]; then
  echo "PASS: deployment_mode stayed this plugin's own classification ($DM); platform_deployment_mode=$PDM"
else
  echo "FAIL: deployment_mode is $DM, expected the local classification $LOCAL_EXPECTED (platform_deployment_mode=$PDM)" >&2
  RC=1
fi

exit "$RC"
