#!/usr/bin/env bash
# Runtime proof for the ADR-065 PEP capability handshake
# (getaxonflow/axonflow-enterprise#3763).
#
# Two stages, and both drive the plugin's ACTUAL shipped shell - no
# reimplementation of the document, no reimplementation of the encoder.
#
#   Stage 1 (always) - the behaviour matrix plus its MUTATION GATE. The shipped
#   builder must produce the platform's own bytes for a valid audience and
#   NOTHING for every malformed one. The gate then plants each defect in a COPY
#   of the shipped script and requires the matrix to go red, so a green stage 1
#   is evidence rather than decoration.
#
#   Stage 2 (when a real AxonFlow agent is reachable) - the honest end of the
#   claim. Sends the declaration the shipped script built to a REAL agent on a
#   real governed route and requires the agent to ACCEPT it, then sends a
#   deliberately malformed one and requires a 400 that NAMES the header. Nothing
#   in this stage knows what the platform's grammar is; the agent decides.
#
# Stage 2 is skipped when no agent is reachable, which is the norm on CI
# runners. It is never the only evidence: stage 1 covers the encoding
# deterministically.
#
# Run:
#   ./runtime-e2e/pep_capability_handshake/test.sh
#   AXONFLOW_ENDPOINT=http://localhost:8080 ./runtime-e2e/pep_capability_handshake/test.sh

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_PATH="${PLUGIN_DIR}/scripts/pep-handshake.sh"
AUDIENCE="axonflow-decision-proof"

# Captured from the PLATFORM's own shipped encoder
# (contract.PEPHandshake.Encode), not regenerated from this plugin's output.
GOLDEN="eyJwcm9maWxlX3ZlcnNpb24iOjEsInBlcF9pZCI6ImNsYXVkZS1jb2RlLXBsdWdpbiIsImF1ZGllbmNlIjoiYXhvbmZsb3ctZGVjaXNpb24tcHJvb2YiLCJjYXBhYmlsaXRpZXMiOltdfQ"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

build_with() {
  # $1 = script path, $2 = audience. Echoes the built handshake (or empty).
  ( unset AXONFLOW_PEP_HANDSHAKE
    export AXONFLOW_PEP_AUDIENCE="$2"
    # shellcheck disable=SC1090
    . "$1" 2>/dev/null
    echo "${AXONFLOW_PEP_HANDSHAKE:-}" )
}

echo "=== stage 1: the shipped builder, and the mutation gate that makes it evidence ==="

# --- the behaviour matrix ---------------------------------------------------
matrix() {
  # $1 = script under test. Returns 0 when every property holds.
  local s="$1" out
  out=$(build_with "$s" "$AUDIENCE");            [ "$out" = "$GOLDEN" ] || return 1
  out=$(build_with "$s" "");                     [ -z "$out" ] || return 1
  out=$(build_with "$s" "has spaces");           [ -z "$out" ] || return 1
  out=$(build_with "$s" "-leading-hyphen");      [ -z "$out" ] || return 1
  out=$(build_with "$s" "$(printf 'aud\nhas spaces')"); [ -z "$out" ] || return 1
  return 0
}

if matrix "$SCRIPT_PATH"; then
  pass "the shipped builder emits the platform's bytes and refuses every malformed audience"
else
  fail "the shipped builder failed its own behaviour matrix"
fi

# --- the mutation gate ------------------------------------------------------
# A matrix that cannot go red is not evidence. Each mutant below is a defect a
# real edit could introduce; the matrix must detect every one.
MUT_DIR=$(mktemp -d)
trap 'rm -rf "$MUT_DIR"' EXIT

plant() {
  # $1 = label, $2 = sed program
  local label="$1" prog="$2" copy="${MUT_DIR}/mutant.sh"
  cp "$SCRIPT_PATH" "$copy"
  sed -i.bak "$prog" "$copy" 2>/dev/null || sed -i '' "$prog" "$copy"
  if matrix "$copy"; then
    fail "MUTANT SURVIVED (${label}) - the matrix cannot detect this defect, so a green run proves nothing about it"
  else
    pass "mutant killed: ${label}"
  fi
}

# The grammar check deleted entirely: every malformed audience would be built.
plant "the audience grammar check removed" 's/grep -qE/grep -qE --invert-match-DISABLED/'
# The newline guard removed: grep is line-based, so a multi-line audience would
# pass on its first line and put a raw newline inside a JSON string.
plant "the multi-line guard removed" 's/\[ "\$_pep_flat" = "\$AXONFLOW_PEP_AUDIENCE" \]/[ 1 = 1 ]/'
# The capabilities member dropped: an OMITTED member is MALFORMED to the
# platform, while [] is a declaration. The two are not interchangeable.
plant "the capabilities member omitted" 's/,"capabilities":\[\]//'

echo
echo "=== stage 2: a real agent decides ==="
ENDPOINT="${AXONFLOW_ENDPOINT:-}"
if [ -z "$ENDPOINT" ] || ! curl -sf --max-time 5 "${ENDPOINT}/health" >/dev/null 2>&1; then
  echo "  SKIP: no reachable agent (set AXONFLOW_ENDPOINT to run this stage)"
else
  HS=$(build_with "$SCRIPT_PATH" "$AUDIENCE")
  AUTH=()
  [ -n "${AXONFLOW_AUTH:-}" ] && AUTH=(-H "Authorization: Basic ${AXONFLOW_AUTH}")

  BODY=$(printf '{"client_id":"%s","tenant_id":"%s","connector_type":"postgres","tool":"query","operation":"query","statement":"select 1"}' \
    "${AXONFLOW_CLIENT_ID:-}" "${AXONFLOW_CLIENT_ID:-}")

  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST \
    "${ENDPOINT}/api/v1/mcp/check-input" -H 'Content-Type: application/json' \
    "${AUTH[@]}" -H "X-Axonflow-PEP-Handshake: ${HS}" -d "$BODY")
  if [ "$CODE" != "400" ]; then
    pass "a real agent ACCEPTED the declaration this plugin builds (HTTP ${CODE})"
  else
    fail "a real agent refused this plugin's declaration as malformed (HTTP 400) - the encoding disagrees with the platform"
  fi

  # The other direction: the agent really is checking, so a green above is not
  # explained by an agent that ignores the header.
  BAD=$(curl -s --max-time 20 -X POST \
    "${ENDPOINT}/api/v1/mcp/check-input" -H 'Content-Type: application/json' \
    "${AUTH[@]}" -H "X-Axonflow-PEP-Handshake: !!!not-base64!!!" -d "$BODY")
  if grep -q "X-Axonflow-PEP-Handshake" <<<"$BAD"; then
    pass "the same agent REFUSES a malformed declaration and names the header"
  else
    fail "the agent did not refuse a malformed declaration; it may not be reading the header at all, which would make the assertion above vacuous"
  fi
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
