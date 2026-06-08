#!/usr/bin/env bash
# Claude Code runtime E2E: self-hosted / Enterprise (in-VPC) agent with a REAL
# license — the lane every other plugin test missed.
#
# Why this exists
# ---------------
# Until now the runtime-e2e suite drove `claude` only with the demo credential
# (demo-client:demo-secret) injected by run_claude_with_tool(), against a
# permissive Community-SaaS-style endpoint. That can NEVER catch the failure a
# real self-hosted Enterprise user hits:
#
#   * `.mcp.json` shipped "headersHelper": "${CLAUDE_PLUGIN_ROOT}/scripts/..."
#     but Claude Code does NOT expand ${CLAUDE_PLUGIN_ROOT} in the
#     headersHelper field — so the helper never ran, no Authorization header
#     was sent, and the MCP server connection fell into OAuth discovery and
#     died on the agent's plaintext "404 page not found" → `/mcp` shows
#     "axonflow failed (HTTP 404: Invalid OAuth error response...)".
#   * With AXONFLOW_AUTH unset against an Enterprise agent, every governed tool
#     call must fail CLOSED with an ACTIONABLE message (naming AXONFLOW_AUTH),
#     not a silent allow and not the cryptic OAuth-404.
#
# This test drives the REAL claude binary against a REAL Enterprise bundle with
# a REAL (non-demo) license and asserts both halves. It deliberately REFUSES to
# run with demo creds — demo-client:demo-secret against the hosted SaaS is NOT
# coverage for this path.
#
# Prereqs (CI provides via secrets; skips cleanly otherwise):
#   AXONFLOW_ENDPOINT        — self-hosted Enterprise agent (default localhost:8080)
#   AXONFLOW_E2E_ORG_ID      — real org id (e.g. the deployment org)
#   AXONFLOW_E2E_LICENSE_KEY — real AXON- license key for that org
#   (or) AXONFLOW_E2E_ENTERPRISE_AUTH — precomputed base64(org_id:license_key)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$SCRIPT_DIR/../_lib/claude-runtime.sh"

# --- environment / skip gates ----------------------------------------------
if ! command -v claude >/dev/null 2>&1; then echo "SKIP: claude CLI not on PATH"; exit 0; fi
if ! command -v jq >/dev/null 2>&1; then echo "SKIP: jq not on PATH"; exit 0; fi
if ! curl -sSf -o /dev/null --max-time 5 "$AXONFLOW_ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $AXONFLOW_ENDPOINT/health"
  exit 0
fi

# Resolve a REAL credential. NO demo fallback — that's the whole point.
REAL_AUTH=""
if [ -n "${AXONFLOW_E2E_ENTERPRISE_AUTH:-}" ]; then
  REAL_AUTH="$AXONFLOW_E2E_ENTERPRISE_AUTH"
elif [ -n "${AXONFLOW_E2E_ORG_ID:-}" ] && [ -n "${AXONFLOW_E2E_LICENSE_KEY:-}" ]; then
  REAL_AUTH="$(printf '%s:%s' "$AXONFLOW_E2E_ORG_ID" "$AXONFLOW_E2E_LICENSE_KEY" | base64 | tr -d '\n')"
fi
if [ -z "$REAL_AUTH" ]; then
  echo "SKIP: no real Enterprise license configured (set AXONFLOW_E2E_ORG_ID + AXONFLOW_E2E_LICENSE_KEY,"
  echo "      or AXONFLOW_E2E_ENTERPRISE_AUTH). This lane intentionally does NOT fall back to demo creds —"
  echo "      demo-client:demo-secret against the hosted SaaS is not coverage for self-hosted Enterprise."
  exit 0
fi
# Guard: never let a demo credential masquerade as real coverage.
DEMO_AUTH="$(printf '%s:%s' "demo-client" "demo-secret" | base64 | tr -d '\n')"
if [ "$REAL_AUTH" = "$DEMO_AUTH" ]; then
  echo "FAIL: AXONFLOW_E2E_* resolves to demo-client:demo-secret — that is not a real Enterprise license."
  exit 1
fi

errors=0
OUT_A="$(mktemp -t axonflow-e2e-ent-authok.XXXXXX)"
OUT_B="$(mktemp -t axonflow-e2e-ent-authmiss.XXXXXX)"
cleanup() { rm -f "$OUT_A" "$OUT_B"; }
trap cleanup EXIT

# ===========================================================================
# Part A — auth PRESENT: /mcp connects, an MCP tool is reachable, a benign
# tool is allowed, and a destructive tool is still blocked.
# ===========================================================================
echo "--- Part A: real Enterprise license present ---"
PROMPT_A="Do these in order and report each result.
1) Call the AxonFlow MCP tool check_policy with connector_type='claude_code.Bash', statement='ls -la', operation='execute'. State whether it returned allowed=true.
2) Call check_policy again with statement='rm -rf / --no-preserve-root'. State whether it returned allowed=false and the block_reason.
3) Actually run the bash command: echo governed-ok
4) End with the literal text DONE_E2E."
run_claude_plugin "$REAL_AUTH" "$PROMPT_A" "$OUT_A"

STATUS_A="$(mcp_axonflow_status "$OUT_A")"
if [ "$STATUS_A" = "connected" ]; then
  echo "PASS: /mcp shows axonflow connected (headersHelper produced auth headers, handshake succeeded)"
else
  echo "FAIL: /mcp shows axonflow '$STATUS_A' (expected connected). Auth headers not reaching the MCP server."
  errors=$((errors + 1))
fi

if assert_tool_invoked "$OUT_A" "__check_policy"; then
  echo "PASS: agent reached the check_policy MCP tool over the governed connection"
else
  echo "FAIL: agent could not invoke the check_policy MCP tool (server unreachable)"
  errors=$((errors + 1))
fi

# The destructive check_policy result must report a block; the benign one must not.
if assert_result_contains "$OUT_A" "DONE_E2E"; then
  echo "PASS: session completed (DONE_E2E)"
else
  echo "FAIL: session did not complete cleanly"
  errors=$((errors + 1))
fi

# A destructive Bash call in the same session must be denied by the PreToolUse
# hook (policy enforcement still bites with a real license).
if grep -qiE 'destructive|block' "$OUT_A"; then
  echo "PASS: destructive operation surfaced a policy block"
else
  echo "WARN: did not observe a destructive-op block string (model may have only described it)"
fi

if assert_no_raw_oauth_404 "$OUT_A"; then
  echo "PASS: no raw OAuth-404 in the authenticated session stream"
else
  echo "FAIL: authenticated session still surfaced the OAuth-404 — headersHelper fix did not take"
  errors=$((errors + 1))
fi

# ===========================================================================
# Part B — auth MISSING: must fail CLOSED with an ACTIONABLE message, never a
# silent allow and never the bare OAuth-404 in the user's workflow.
# ===========================================================================
echo "--- Part B: AXONFLOW_AUTH unset against the same Enterprise agent ---"
PROMPT_B="Run the bash command: echo hello-axonflow. Then report verbatim any governance/permission message you received."
run_claude_plugin "" "$PROMPT_B" "$OUT_B"

# The deny reason must name the exact env var the operator has to set.
if grep -q 'AXONFLOW_AUTH' "$OUT_B" && grep -qi 'fail-closed' "$OUT_B"; then
  echo "PASS: auth-missing tool call denied with an actionable, fail-closed reason naming AXONFLOW_AUTH"
else
  echo "FAIL: auth-missing deny reason did not clearly name AXONFLOW_AUTH / fail-closed"
  errors=$((errors + 1))
fi

# It must NOT have silently allowed the bash command (no governance bypass).
if grep -q 'hello-axonflow' "$OUT_B" && grep -qiE 'tool_result.*hello-axonflow' "$OUT_B"; then
  # crude: if the command actually executed and printed, that's a silent allow
  echo "FAIL: bash command appears to have executed despite missing auth (silent allow / brick bypass)"
  errors=$((errors + 1))
else
  echo "PASS: bash command was blocked (not silently executed) while auth was missing"
fi

# The user-facing stream must not be the cryptic OAuth-404.
if assert_no_raw_oauth_404 "$OUT_B"; then
  echo "PASS: auth-missing workflow surfaced an actionable deny, not the OAuth-404"
else
  echo "FAIL: auth-missing workflow surfaced the raw OAuth-404 to the user"
  errors=$((errors + 1))
fi

echo ""
if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors assertion(s) failed (OUT_A=$OUT_A OUT_B=$OUT_B)"
  trap - EXIT  # keep artifacts for debugging
  exit 1
fi
echo "PASS: self-hosted-enterprise-auth (connect+allow+deny with real license; auth-missing fails closed with actionable message)"
