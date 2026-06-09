#!/usr/bin/env bash
# Claude Code runtime E2E — axonflow-claude-plugin#94.
#
# Reproduces, against the REAL claude binary + the REAL plugin + a REAL
# self-hosted/Enterprise agent, the bug a design partner hit: MCP tools/call
# 401'd on Enterprise while the per-call hooks governed fine.
#
# Root cause: with AXONFLOW_AUTH unset and a Community-SaaS try-registration.json
# on disk (left over from any prior community-saas run), the inline .mcp.json
# `headersHelper` fell back to the cs_<uuid> credential REGARDLESS of endpoint
# and sent it to the Enterprise agent, which rejected it ("invalid license key
# prefix (expected AXON-)") → HTTP 401 → `/mcp` showed "axonflow failed", and no
# axonflow MCP tool could execute. The hooks never used the cs_ credential on an
# Enterprise endpoint, so they kept working — exactly the asymmetry reported.
#
# This test plants that exact trap (a stale cs_ registration) and asserts:
#   Part A — with a durable self-hosted credential on disk and AXONFLOW_AUTH
#            UNSET, the MCP connection authenticates and an axonflow MCP tool
#            ACTUALLY EXECUTES (the fix uses self-hosted-auth.json, not cs_).
#   Part B — with NO self-hosted credential and AXONFLOW_AUTH still unset, the
#            connection fails CLOSED — it must NOT silently authenticate as the
#            stale cs_ tenant (no cross-deployment credential leak).
#
# Hermetic: uses AXONFLOW_CONFIG_DIR to sandbox the AxonFlow credential files in
# a tmp dir, so the user's real ~/.config/axonflow is never touched. claude's
# own auth keeps using the real HOME.
#
# Prereqs (skips cleanly otherwise):
#   AXONFLOW_ENDPOINT        — self-hosted Enterprise agent (default localhost:8080)
#   AXONFLOW_E2E_ORG_ID + AXONFLOW_E2E_LICENSE_KEY  (or AXONFLOW_E2E_ENTERPRISE_AUTH=base64(org:key))
# Optional:
#   AXONFLOW_E2E_AGENT_CONTAINER — docker container name of the agent; when set
#     and docker is available, Part B additionally asserts no cs_ auth attempt
#     reached the agent during the run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"

# --- skip gates -------------------------------------------------------------
command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
curl -sSf -o /dev/null --max-time 5 "$AXONFLOW_ENDPOINT/health" 2>/dev/null || {
  echo "SKIP: AxonFlow stack not reachable at $AXONFLOW_ENDPOINT/health"; exit 0; }

# Resolve a REAL Enterprise credential — never a demo fallback.
ORG_ID="${AXONFLOW_E2E_ORG_ID:-}"
LICENSE_KEY="${AXONFLOW_E2E_LICENSE_KEY:-}"
if [ -z "$ORG_ID" ] || [ -z "$LICENSE_KEY" ]; then
  if [ -n "${AXONFLOW_E2E_ENTERPRISE_AUTH:-}" ]; then
    decoded="$(printf '%s' "$AXONFLOW_E2E_ENTERPRISE_AUTH" | base64 -d 2>/dev/null)"
    ORG_ID="${decoded%%:*}"
    LICENSE_KEY="${decoded#*:}"
  fi
fi
if [ -z "$ORG_ID" ] || [ -z "$LICENSE_KEY" ]; then
  echo "SKIP: no real Enterprise license configured (set AXONFLOW_E2E_ORG_ID + AXONFLOW_E2E_LICENSE_KEY,"
  echo "      or AXONFLOW_E2E_ENTERPRISE_AUTH=base64(org:key)). This lane does NOT use demo creds."
  exit 0
fi

errors=0
SANDBOX="$(mktemp -d -t axonflow-cfg.XXXXXX)"
OUT_A="$(mktemp -t axonflow-94-A.XXXXXX)"
OUT_B="$(mktemp -t axonflow-94-B.XXXXXX)"
cleanup() { rm -rf "$SANDBOX" "$OUT_A" "$OUT_B"; }
trap cleanup EXIT

mkdir -p "$SANDBOX"
chmod 0700 "$SANDBOX"
# Plant the cross-deployment trap: a stale Community-SaaS registration.
printf '%s' '{"tenant_id":"cs_e2e_stale_0000","secret":"stale-cs-secret","expires_at":"2030-01-01T00:00:00Z"}' \
  > "$SANDBOX/try-registration.json"
chmod 0600 "$SANDBOX/try-registration.json"

# mcp_status <file> → connected|failed|pending|absent (Claude Code's own /mcp view)
mcp_status() {
  grep '^{' "$1" 2>/dev/null | jq -r \
    'select(.type=="system" and .subtype=="init") | .mcp_servers[]? | select(.name|startswith("plugin:axonflow")) | .status' \
    2>/dev/null | head -1 | grep . || printf 'absent'
}
# tool_executed <file> <suffix> → 0 if an MCP tool ending in <suffix> ran
tool_executed() {
  local v
  v=$(grep '^{' "$1" 2>/dev/null | jq -c --arg s "$2" \
    'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name|endswith($s)))' \
    2>/dev/null | head -1)
  [ -n "$v" ]
}
no_oauth404() { ! grep -qiE 'Invalid OAuth error response|Raw body: 404 page not found' "$1"; }

run_cc() { # <output-file> <prompt> ; AXONFLOW_AUTH intentionally UNSET
  local out="$1" prompt="$2" tmpd
  tmpd="$(mktemp -d -t axonflow-cc.XXXXXX)"
  (
    cd "$tmpd"
    unset AXONFLOW_AUTH
    export AXONFLOW_ENDPOINT="$AXONFLOW_ENDPOINT"
    export AXONFLOW_CONFIG_DIR="$SANDBOX"
    claude --plugin-dir "$PLUGIN_DIR" --print --output-format stream-json --verbose \
      --dangerously-skip-permissions "$prompt" 2>&1
  ) > "$out" || true
  rm -rf "$tmpd"
}

PROMPT="Call the AxonFlow MCP tool check_policy with connector_type='claude_code.Bash', statement='ls -la', operation='execute'. State whether it returned allowed=true. Then end with the literal text DONE_E2E."

# ===========================================================================
# Part A — durable self-hosted credential present, AXONFLOW_AUTH unset, stale
# cs_ registration also present. The headersHelper MUST use self-hosted-auth.json
# (not cs_) → MCP connects → the tool EXECUTES.
# ===========================================================================
echo "--- Part A: self-hosted-auth.json fallback + stale cs_ trap (AXONFLOW_AUTH unset) ---"
AXONFLOW_CONFIG_DIR="$SANDBOX" bash "$PLUGIN_DIR/scripts/login.sh" --self-hosted "$ORG_ID" "$LICENSE_KEY" >/dev/null 2>&1
if [ ! -f "$SANDBOX/self-hosted-auth.json" ]; then
  echo "FAIL: login.sh --self-hosted did not write self-hosted-auth.json"; errors=$((errors+1))
fi

run_cc "$OUT_A" "$PROMPT"

STATUS_A="$(mcp_status "$OUT_A")"
if [ "$STATUS_A" = "connected" ]; then
  echo "PASS: /mcp connected via self-hosted-auth.json (cs_ trap not used)"
else
  echo "FAIL: /mcp status '$STATUS_A' (expected connected) — file fallback did not authenticate"; errors=$((errors+1))
fi
if tool_executed "$OUT_A" "check_policy"; then
  echo "PASS: check_policy MCP tool EXECUTED over the governed connection"
else
  echo "FAIL: check_policy MCP tool did not execute (the hooks-only tests missed this path)"; errors=$((errors+1))
fi
if grep -q 'DONE_E2E' "$OUT_A" 2>/dev/null; then
  echo "PASS: session completed (DONE_E2E)"
else
  echo "FAIL: session did not complete cleanly"; errors=$((errors+1))
fi
if no_oauth404 "$OUT_A"; then
  echo "PASS: no raw OAuth-404 in the authenticated session"
else
  echo "FAIL: authenticated session still surfaced the OAuth-404"; errors=$((errors+1))
fi

# ===========================================================================
# Part B — remove the self-hosted credential; only the stale cs_ remains, with
# AXONFLOW_AUTH unset. The connection MUST fail closed — it must NOT silently
# authenticate as the cs_ tenant (the leak the fix removes).
# ===========================================================================
echo "--- Part B: no self-hosted credential, only stale cs_ (no cross-deployment leak) ---"
rm -f "$SANDBOX/self-hosted-auth.json"

# Optional agent-log boundary for the no-leak assertion.
LOG_SINCE=""
if [ -n "${AXONFLOW_E2E_AGENT_CONTAINER:-}" ] && command -v docker >/dev/null 2>&1; then
  LOG_SINCE="$(date -u +%Y-%m-%dT%H:%M:%S)"
  sleep 1
fi

run_cc "$OUT_B" "$PROMPT"

STATUS_B="$(mcp_status "$OUT_B")"
if [ "$STATUS_B" != "connected" ]; then
  echo "PASS: /mcp did not connect ('$STATUS_B') — no silent fallback to a credential"
else
  echo "FAIL: /mcp connected with no real credential — a stale credential was used"; errors=$((errors+1))
fi
if tool_executed "$OUT_B" "check_policy"; then
  echo "FAIL: check_policy executed with no valid credential (stale cs_ leaked through)"; errors=$((errors+1))
else
  echo "PASS: no axonflow MCP tool executed without a valid credential"
fi

# Strong no-leak assertion when the agent log is reachable: the cs_ tenant must
# NOT appear as an auth attempt during Part B.
if [ -n "$LOG_SINCE" ]; then
  if docker logs "$AXONFLOW_E2E_AGENT_CONTAINER" --since "$LOG_SINCE" 2>&1 | grep -q 'cs_e2e_stale_0000'; then
    echo "FAIL: agent log shows the cs_ credential was sent to the Enterprise agent (leak)"; errors=$((errors+1))
  else
    echo "PASS: agent log shows NO cs_ credential reached the Enterprise agent during Part B"
  fi
else
  echo "INFO: AXONFLOW_E2E_AGENT_CONTAINER not set — skipping agent-log no-leak assertion (unit test covers it)"
fi

echo ""
if [ "$errors" -gt 0 ]; then
  echo "FAIL: mcp-self-hosted-auth-fallback ($errors assertion(s); OUT_A=$OUT_A OUT_B=$OUT_B)"
  trap - EXIT
  exit 1
fi
echo "PASS: mcp-self-hosted-auth-fallback (#94 — durable Enterprise MCP auth, no cs_ cross-deployment leak)"
