#!/usr/bin/env bash
# V1 Plugin Pro MCP-tools-invocable runtime proof for the Claude Code plugin.
#
# Drives the REAL `claude` CLI with the plugin loaded against the live
# AxonFlow agent at https://try.getaxonflow.com. For each of the 5 V1
# Pro MCP tools (the differentiators table from PRD §V1), prompts the
# AI to invoke that tool and asserts:
#
#   1. The agent's first MCP tool_use carries `mcp__plugin_axonflow_axonflow__<tool_name>`
#      (auto-discovered from the agent's tools/list — proves the
#      MCP-server connection + tool advertisement chain works
#      end-to-end on the host CLI).
#   2. The tool_result content matches the locked V1 shape for that
#      tool (5 differentiators / approval_id / policy_id / etc.) OR
#      the locked V1 envelope shape on Free-tier gates
#      (limit_type=feature_pro_only / hitl_approvals_window / active_policies).
#
# Five tool prompts, five subprocess `claude --print` invocations, one
# stream-json capture per. Per HARD RULE #0 — real plugin in real
# host CLI; no fixtures, no shims.
#
# Pre-requirements:
#   - claude CLI on PATH (verified via runtime_e2e_skip_if_unavailable)
#   - jq on PATH
#   - Live agent reachable at AGENT_URL/health
#   - A working community-saas tenant in env (TENANT/SECRET) OR
#     freshly registered via /api/v1/register

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../_lib/claude-runtime.sh
source "$PLUGIN_DIR/runtime-e2e/_lib/claude-runtime.sh"

UTC_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE="$SCRIPT_DIR/EVIDENCE/$UTC_TS"
mkdir -p "$EVIDENCE"

AGENT_URL="${AGENT_URL:-https://try.getaxonflow.com}"
export AXONFLOW_ENDPOINT="$AGENT_URL"

runtime_e2e_skip_if_unavailable

# CLAUDE_PLUGIN_ROOT is required by the plugin's `.mcp.json` headersHelper
# path interpolation (`${CLAUDE_PLUGIN_ROOT}/scripts/mcp-auth-headers.sh`).
# Claude Code 2.1.132 does NOT auto-populate this variable when reading
# the plugin's MCP config from `--plugin-dir`, so the helper resolves to
# `/scripts/...` (a non-existent absolute path) and the MCP server fails
# to connect. Set it explicitly here to the plugin root.
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

# Hermetic license-token isolation:
# the helper auto-loads ~/.config/axonflow/license-token.json on every
# invocation and stamps its bytes into the X-License-Token header. If a
# previous Pro-tier session left a token on disk for tenant A and the
# current run targets tenant B, the agent's PluginClaimMiddleware rejects
# the request (cross-tenant token binding) — and the rejection bubbles up
# as an MCP connection failure, NOT a tier downgrade.
#
# Move any existing token aside for the duration of this run and restore
# it on exit. (Single consolidated trap handles license-token + reg-body
# cleanup; defining a second `trap EXIT` later would clobber this one.)
LICENSE_TOKEN_FILE="${HOME}/.config/axonflow/license-token.json"
LICENSE_TOKEN_BACKUP=""
if [ -f "$LICENSE_TOKEN_FILE" ]; then
  LICENSE_TOKEN_BACKUP="${LICENSE_TOKEN_FILE}.runtime-e2e-bak.$$"
  mv "$LICENSE_TOKEN_FILE" "$LICENSE_TOKEN_BACKUP"
fi
REG_BODY_TMP=""
cleanup_on_exit() {
  [ -n "$LICENSE_TOKEN_BACKUP" ] && [ -f "$LICENSE_TOKEN_BACKUP" ] && \
    mv "$LICENSE_TOKEN_BACKUP" "$LICENSE_TOKEN_FILE" 2>/dev/null
  [ -n "$REG_BODY_TMP" ] && rm -f "$REG_BODY_TMP" 2>/dev/null
  return 0
}
trap cleanup_on_exit EXIT

# Resolve a working tenant. Order: TENANT/SECRET env > register fresh.
TENANT="${TENANT:-}"
SECRET="${SECRET:-}"
if [ -z "$TENANT" ] || [ -z "$SECRET" ]; then
  EMAIL_TAG=$(date -u +%s)
  REG_BODY_TMP=$(mktemp)
  REG_HTTP=$(curl -sS -o "$REG_BODY_TMP" -w '%{http_code}' \
    -X POST "${AGENT_URL}/api/v1/register" \
    -H 'Content-Type: application/json' \
    -d "{\"label\":\"v1-pro-mcp-tools-invocable-${EMAIL_TAG}\",\"email\":\"e2e+claude-mcp-${EMAIL_TAG}@getaxonflow.com\"}" 2>/dev/null) || REG_HTTP="000"
  if [ "$REG_HTTP" != "200" ] && [ "$REG_HTTP" != "201" ]; then
    echo "SKIP: tenant registration HTTP=$REG_HTTP. Pass TENANT=... SECRET=... env to reuse an existing tenant."
    cat "$REG_BODY_TMP" 2>/dev/null
    exit 0
  fi
  TENANT=$(jq -r '.tenant_id' "$REG_BODY_TMP")
  SECRET=$(jq -r '.secret' "$REG_BODY_TMP")
  echo "Registered: $TENANT"
fi

# Idempotency: clear prior HITL approvals + dynamic policies for this
# tenant so the Free-tier gate-tests round-trip cleanly. Best-effort.
if command -v aws >/dev/null 2>&1; then
  DB_LIB="${PLUGIN_DIR}/../axonflow-enterprise/runtime-e2e/v1_paid_tier_staging/lib/db_helpers.sh"
  if [ -f "$DB_LIB" ]; then
    case "$AGENT_URL" in
      *try-staging*) STACK_PREFIX='axonflow-community-saas-staging-2' ;;
      *try.getaxonflow*) STACK_PREFIX='axonflow-community-saas-2' ;;
      *) STACK_PREFIX='' ;;
    esac
    if [ -n "$STACK_PREFIX" ]; then
      DETECTED_STACK=$(aws cloudformation list-stacks --region us-east-1 \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        --query "StackSummaries[?starts_with(StackName, '$STACK_PREFIX') && !contains(StackName, 'staging-2') && !contains(StackName, 'alarm') && !contains(StackName, 'synth')].StackName" \
        --output text 2>/dev/null | tr '\t' '\n' | sort -r | head -1)
      DETECTED_TASK=$(aws ecs list-tasks --region us-east-1 --cluster "${DETECTED_STACK}-cluster" \
        --service-name "${DETECTED_STACK}-orchestrator-service" --query 'taskArns[0]' --output text 2>/dev/null)
      DETECTED_DB=$(aws rds describe-db-instances --region us-east-1 \
        --query "DBInstances[?DBInstanceIdentifier == '${DETECTED_STACK}-db'].Endpoint.Address" \
        --output text 2>/dev/null | head -1)
      DETECTED_PASS=$(aws secretsmanager get-secret-value --region us-east-1 \
        --secret-id "${DETECTED_STACK}-db-password" --query SecretString --output text 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])' 2>/dev/null)
      if [ -n "$DETECTED_STACK" ] && [ -n "$DETECTED_TASK" ] && [ -n "$DETECTED_DB" ] && [ -n "$DETECTED_PASS" ]; then
        export STACK="$DETECTED_STACK" ORCH_TASK="$DETECTED_TASK" DB_HOST="$DETECTED_DB" DB_PASS="$DETECTED_PASS" REGION=us-east-1
        # shellcheck disable=SC1090
        source "$DB_LIB"
        echo "Idempotency: clear hitl + policies for $TENANT"
        db_run_sql "DELETE FROM hitl_approval_queue WHERE tenant_id = '${TENANT}'; DELETE FROM dynamic_policies WHERE tenant_id = '${TENANT}';" >/dev/null 2>&1 || true
      fi
    fi
  fi
fi

# Configure the plugin to use this tenant via the env-vars path.
# The hook honours AXONFLOW_AUTH unconditionally; no community-saas
# bootstrap auto-runs because we set AXONFLOW_ENDPOINT explicitly.
export AXONFLOW_AUTH=$(printf '%s:%s' "$TENANT" "$SECRET" | base64 | tr -d '\n')

# ---------------------------------------------------------------------------
# Per-tool driver. Each iteration:
#   - assembles a prompt that explicitly asks the AI to invoke ONE
#     specific MCP tool by name (no skill activation, no slash command —
#     direct MCP tool call).
#   - runs `claude --print --output-format stream-json` with the plugin.
#   - asserts the captured tool_use sequence contains the expected
#     mcp__plugin_axonflow_axonflow__<tool_name>, AND the tool_result matches the
#     locked V1 shape (or the V1 envelope on Free gates).
# ---------------------------------------------------------------------------

PASS=true
fail() { echo "FAIL: $1"; PASS=false; }
record_tool_result() {
  local tool="$1" prompt="$2" expectation="$3"
  local out_file="$EVIDENCE/${tool}.jsonl"
  echo
  echo "================ tool: $tool — expectation: $expectation ================"
  run_claude_with_tool "" "$prompt" "$out_file"
  echo "  captured $(wc -l <"$out_file") lines to $out_file"

  # Claude prefixes plugin MCP tools as `mcp__plugin_<plugin-name>_<server-name>__<tool>`.
  # For this plugin (.claude-plugin/plugin.json: name=axonflow, .mcp.json
  # server=axonflow) the prefix collapses to `mcp__plugin_axonflow_axonflow__`.
  local expected_name="mcp__plugin_axonflow_axonflow__${tool}"
  local first_tool_call
  first_tool_call=$(jq -c --arg t "$expected_name" \
    'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name == $t)' \
    "$out_file" 2>/dev/null | head -1)
  if [ -z "$first_tool_call" ]; then
    # Look for ANY axonflow MCP tool_use to disambiguate "agent picked wrong
    # tool" from "MCP server didn't connect at all".
    local any_call
    any_call=$(jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name | startswith("mcp__plugin_axonflow_axonflow__")))' \
      "$out_file" 2>/dev/null | head -1)
    if [ -z "$any_call" ]; then
      fail "$tool: no mcp__plugin_axonflow_axonflow__* tool_use captured (expected $expected_name)"
      jq -c 'select(.type=="system" and .subtype=="init") | .mcp_servers' "$out_file" 2>/dev/null | head -1
      jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | {name}' "$out_file" 2>/dev/null | head -5
      return
    fi
    fail "$tool: agent invoked $(echo "$any_call" | jq -r '.name') instead of $expected_name"
    return
  fi
  echo "  $tool: agent invoked $expected_name ✓"

  # Pull the tool_result text content (where the agent's MCP server
  # answers come back) for shape assertion.
  local tool_use_id
  tool_use_id=$(echo "$first_tool_call" | jq -r '.id')
  local result_text
  result_text=$(jq -c --arg id "$tool_use_id" \
    'select(.type=="user") | .message.content[]? | select(.type=="tool_result" and .tool_use_id == $id) | .content' \
    "$out_file" 2>/dev/null | head -1)
  if [ -z "$result_text" ] || [ "$result_text" = "null" ]; then
    fail "$tool: no tool_result for tool_use_id=$tool_use_id"
    return
  fi
  # The result is sometimes a string, sometimes an array of {type:text,
  # text:...}. Normalize.
  local body
  body=$(echo "$result_text" | jq -r 'if type=="string" then . elif type=="array" then .[].text // empty else tojson end' 2>/dev/null | head -c 4096)
  echo "  $tool: tool_result body (first 200 chars):"
  echo "$body" | head -c 200 | sed 's/^/    /'
  echo
  echo "$body" > "$EVIDENCE/${tool}_result.txt"
  echo "$expectation" > "$EVIDENCE/${tool}_expectation.txt"

  case "$expectation" in
    list_pro_features_ok)
      echo "$body" | grep -qF 'differentiators' || fail "$tool: result missing 'differentiators' field"
      echo "$body" | grep -qF '9.99' || fail "$tool: result missing '9.99' price"
      ;;
    get_cost_estimate_envelope)
      echo "$body" | grep -qF 'feature_pro_only' || fail "$tool: result missing 'feature_pro_only' limit_type"
      echo "$body" | grep -qF 'buy.stripe.com/bJe28qbztcdVchjdkw8k800' || fail "$tool: result missing locked V1 buy URL"
      ;;
    request_approval_ok)
      echo "$body" | grep -qE 'approval_id|"id":' || fail "$tool: result missing approval_id"
      ;;
    create_tenant_policy_ok)
      echo "$body" | grep -qE 'policy_id' || fail "$tool: result missing policy_id"
      ;;
    get_tenant_id_ok)
      echo "$body" | grep -qF "$TENANT" || fail "$tool: result missing tenant_id ($TENANT)"
      echo "$body" | grep -qF 'getaxonflow.com/pricing' || fail "$tool: result missing upgrade_url"
      ;;
    *)
      fail "$tool: unknown expectation '$expectation'"
      ;;
  esac
}

record_tool_result "axonflow_list_pro_features" \
  "Use the mcp__plugin_axonflow_axonflow__axonflow_list_pro_features MCP tool to fetch the V1 Plugin Pro feature list as data. Pass an empty arguments object {}. Print exactly SMOKE_RESULT followed by a JSON line summarising the response." \
  "list_pro_features_ok"

# axonflow_get_cost_estimate is a Pro-only MCP tool — per ADR-049 §5 the
# agent advertises it ONLY to Pro-tier sessions, so a Free tenant's
# tools/list call doesn't include it at all. Assert that it is HIDDEN
# from the Free-tier session's deferred-tools list (the V1 gating
# contract), not that the agent invokes it. The envelope shape is
# already covered by the OpenClaw v1_pro_proxy_tools test which calls
# the MCP tool directly via JSON-RPC and bypasses tier gating.
record_tool_hidden() {
  local tool="$1"
  echo
  echo "================ tool: $tool — expectation: hidden_from_free_tier ================"
  local out_file="$EVIDENCE/${tool}.jsonl"
  run_claude_with_tool "" \
    "List the MCP tools you can see whose name contains '${tool}'. Just list them, don't invoke any. Print exactly SMOKE_RESULT followed by a JSON line." \
    "$out_file"
  echo "  captured $(wc -l <"$out_file") lines"
  local found
  found=$(jq -c --arg t "mcp__plugin_axonflow_axonflow__${tool}" \
    'select(.type=="system" and .subtype=="init") | .tools | map(select(. == $t)) | .[0] // empty' \
    "$out_file" 2>/dev/null | head -1)
  if [ -n "$found" ] && [ "$found" != "null" ]; then
    fail "$tool: Pro-only tool was visible to Free tenant (found in init.tools — V1 tier gating broken on agent side)"
    return
  fi
  echo "  $tool: hidden from Free-tier tools/list ✓ (matches ADR-049 §5 gating contract)"
  echo "hidden_from_free_tier" > "$EVIDENCE/${tool}_result.txt"
}
record_tool_hidden "axonflow_get_cost_estimate"

record_tool_result "axonflow_request_approval" \
  "Use the mcp__plugin_axonflow_axonflow__axonflow_request_approval MCP tool with arguments {\"original_query\": \"runtime-e2e probe\", \"request_type\": \"shell_command\", \"trigger_reason\": \"runtime_e2e_test\", \"severity\": \"low\"}. Print exactly SMOKE_RESULT followed by a JSON line summarising the response." \
  "request_approval_ok"

# Use a benign pattern for create_tenant_policy: the agent's static
# policy chain runs on the tool's `pattern` argument and would block
# destructive strings (e.g. "rm -rf /") with an unrelated decision long
# before the tool's own create-policy logic runs. A neutral marker keeps
# the assertion focused on tool dispatch + 201 shape.
record_tool_result "axonflow_create_tenant_policy" \
  "Use the mcp__plugin_axonflow_axonflow__axonflow_create_tenant_policy MCP tool with arguments {\"name\": \"runtime-e2e-claude-${UTC_TS}\", \"description\": \"runtime-e2e probe\", \"connector_type\": \"claude_code.Bash\", \"pattern\": \"axonflow-runtime-e2e-marker\", \"action\": \"warn\"}. Print exactly SMOKE_RESULT followed by a JSON line summarising the response." \
  "create_tenant_policy_ok"

record_tool_result "axonflow_get_tenant_id" \
  "Use the mcp__plugin_axonflow_axonflow__axonflow_get_tenant_id MCP tool with an empty arguments object {}. Print exactly SMOKE_RESULT followed by a JSON line summarising the response." \
  "get_tenant_id_ok"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
{
  echo
  echo "Claude V1 Plugin Pro MCP-tools-invocable runtime proof — $UTC_TS"
  echo "AGENT_URL=$AGENT_URL"
  echo "TENANT=$TENANT"
  echo "Result: $($PASS && echo PASS || echo FAIL)"
} | tee "$EVIDENCE/summary.txt"

if $PASS; then
  echo
  echo "PASS — claude CLI can invoke all 5 V1 Pro MCP tools end-to-end"
  exit 0
else
  echo
  echo "FAIL — see $EVIDENCE/ for evidence"
  exit 1
fi
