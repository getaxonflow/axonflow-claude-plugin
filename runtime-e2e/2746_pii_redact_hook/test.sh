#!/usr/bin/env bash
# Claude Code runtime E2E — axonflow-claude-plugin companion for #2746.
#
# Proves that pre-tool-check.sh handles the check_policy requires_redaction
# response correctly against a REAL running AxonFlow agent:
#
#   Given: agent configured with PII_ACTION=redact
#   When:  pre-tool-check.sh receives a Write tool call with an Indonesia NIK
#   Then:  the hook emits permissionDecision:"deny" with a non-empty
#          additionalContext carrying the agent-masked statement (NIK replaced).
#
# And the clean path:
#
#   When:  pre-tool-check.sh receives a Write with no PII
#   Then:  the hook emits no output (allow / no opinion).
#
# Skip conditions (graceful):
#   - AXONFLOW_ENDPOINT agent not reachable at /health
#   - Agent not configured with PII_ACTION=redact (detected via probe)
#
# Per HARD RULE #0: no mocks. The hook calls the real agent; the agent must
# return requires_redaction:true for the assertion to pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not on PATH"; exit 0; }

AGENT_URL="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
curl -sSf -o /dev/null --max-time 5 "${AGENT_URL}/health" 2>/dev/null || {
  echo "SKIP: AxonFlow agent not reachable at ${AGENT_URL}/health"
  echo "      Set AXONFLOW_ENDPOINT to point to an agent with PII_ACTION=redact"
  exit 0
}

# Probe: does the agent actually return requires_redaction for a NIK statement?
# If not (e.g. PII_ACTION=block or agent is community-saas without redact), skip.
NIK="3174042506780001"
PROBE_OUT=$(mktemp)
PROBE_SESSION_HDR=$(mktemp)
trap 'rm -f "$PROBE_OUT" "$PROBE_SESSION_HDR"' EXIT

curl -s -D "$PROBE_SESSION_HDR" -o /dev/null \
  -X POST "${AGENT_URL}/api/v1/mcp-server" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"rte-2746-probe","version":"1.0"}}}' >/dev/null 2>&1
PROBE_SESSION=$(grep -i '^mcp-session-id:' "$PROBE_SESSION_HDR" | tr -d '\r' | awk '{print $2}')

curl -s -o "$PROBE_OUT" \
  -X POST "${AGENT_URL}/api/v1/mcp-server" -H 'Content-Type: application/json' \
  -H "mcp-session-id: ${PROBE_SESSION}" \
  -d "$(jq -nc --arg s "write NIK ${NIK} to record" \
        '{jsonrpc:"2.0",id:"probe",method:"tools/call",params:{name:"check_policy",arguments:{connector_type:"claude_code.Write",statement:$s,operation:"execute"}}}')" >/dev/null 2>&1
PROBE_TEXT=$(jq -r '.result.content[0].text // empty' < "$PROBE_OUT" 2>/dev/null)
PROBE_RR=$(echo "$PROBE_TEXT" | jq -r 'if has("requires_redaction") then (.requires_redaction | tostring) else "false" end' 2>/dev/null || echo "false")

if [ "$PROBE_RR" != "true" ]; then
  echo "SKIP: agent at ${AGENT_URL} did not return requires_redaction=true for NIK statement"
  echo "      (got probe_rr=${PROBE_RR}). This E2E test requires PII_ACTION=redact on the agent."
  exit 0
fi

errors=0

# --- Test A: Write with NIK → hook denies + additionalContext ---
echo "── Case A: Write with NIK under PII_ACTION=redact ──"
HOOK_INPUT_A=$(jq -nc \
  --arg s "/tmp/customer.txt"$'\n'"NIK ${NIK} in file" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/customer.txt","content":("NIK " + "'"$NIK"'" + " in file")}}')

HOOK_OUT_A=$(printf '%s' "$HOOK_INPUT_A" | \
  AXONFLOW_ENDPOINT="$AGENT_URL" AXONFLOW_AUTH="" \
  bash "$HOOK" 2>/dev/null || true)

DECISION_A=$(echo "$HOOK_OUT_A" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
CONTEXT_A=$(echo "$HOOK_OUT_A" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)

if [ "$DECISION_A" = "deny" ]; then
  echo "✅ PASS case-A: hook emits permissionDecision=deny for NIK Write"
else
  echo "❌ FAIL case-A: expected deny, got '${DECISION_A}'"
  echo "   hook output: $HOOK_OUT_A"
  errors=$((errors + 1))
fi

if [ -n "$CONTEXT_A" ]; then
  echo "✅ PASS case-A: additionalContext is non-empty"
else
  echo "❌ FAIL case-A: additionalContext is empty — Claude won't know what to retry with"
  errors=$((errors + 1))
fi

if ! echo "$CONTEXT_A" | grep -qF "$NIK"; then
  echo "✅ PASS case-A: additionalContext does not contain raw NIK"
else
  echo "❌ FAIL case-A: additionalContext still contains raw NIK '${NIK}'"
  errors=$((errors + 1))
fi

# --- Test B: Write with no PII → hook allows (no output) ---
echo ""
echo "── Case B: clean Write → hook allows ──"
HOOK_INPUT_B=$(jq -nc '{"tool_name":"Write","tool_input":{"file_path":"/tmp/hello.txt","content":"hello world"}}')
HOOK_OUT_B=$(printf '%s' "$HOOK_INPUT_B" | \
  AXONFLOW_ENDPOINT="$AGENT_URL" AXONFLOW_AUTH="" \
  bash "$HOOK" 2>/dev/null || true)

DECISION_B=$(echo "$HOOK_OUT_B" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)

if [ -z "$DECISION_B" ] || [ "$DECISION_B" = "allow" ]; then
  echo "✅ PASS case-B: hook allows clean Write (permissionDecision='${DECISION_B}')"
else
  echo "❌ FAIL case-B: expected allow/empty, got '${DECISION_B}'"
  errors=$((errors + 1))
fi

echo ""
if [ "$errors" -eq 0 ]; then
  echo "✅ All assertions passed"
else
  echo "❌ $errors assertion(s) failed"
  exit 1
fi
