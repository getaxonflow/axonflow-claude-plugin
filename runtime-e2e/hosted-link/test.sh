#!/usr/bin/env bash
# Manual real-Portal/real-Agent proof after staging is restored. Requires an
# owner to approve the printed device code in the verified staging browser.
set -euo pipefail

if [ "${AXONFLOW_HOSTED_E2E_PORTAL:-}" != "https://portal.try-staging.getaxonflow.com" ] ||
   [ "${AXONFLOW_HOSTED_E2E_ENDPOINT:-}" != "https://try-staging.getaxonflow.com" ]; then
  echo 'SKIP: set both exact staging Portal and Agent origins to run Hosted linking' >&2
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
export AXONFLOW_CONFIG_DIR="$WORK/config"

# The Portal approves a secret generated on this workstation; neither this
# script nor the browser receives a reusable credential from a public page.
HOME="$WORK/home" node "$ROOT/scripts/hosted-link.mjs" \
  --portal "$AXONFLOW_HOSTED_E2E_PORTAL" --endpoint "$AXONFLOW_HOSTED_E2E_ENDPOINT" \
  | tee "$WORK/link.out"
file="$AXONFLOW_CONFIG_DIR/hosted-claude-code.json"
test -f "$file"
mode=$(stat -c %a "$file" 2>/dev/null) || mode=""
case "$mode" in ''|*[!0-9]*) mode=$(stat -f %Lp "$file" 2>/dev/null) || mode="" ;; esac
test "$mode" = 600
jq -e '.link_method == "portal-device" and .endpoint == "https://try-staging.getaxonflow.com"' "$file" >/dev/null
secret=$(jq -r .secret "$file")
if grep -Fq "$secret" "$WORK/link.out"; then
  echo 'FAIL: link command printed the reusable secret' >&2
  exit 1
fi

REAL_CURL=$(command -v curl)
mkdir -p "$WORK/bin"
cp "$ROOT/runtime-e2e/hosted-link/observe-curl.sh" "$WORK/bin/curl"
chmod 0700 "$WORK/bin/curl"
HOOK_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo axonflow-hosted-link-probe"}}'

observed_allow() {
  [ -f "$1" ] && grep -Fxq allowed "$1"
}

# Source the exact setup used when launching the editor, then invoke its
# actual hook against the real staging Agent with a harmless synthetic call.
# shellcheck disable=SC2016
env -u AXONFLOW_ENDPOINT -u AXONFLOW_AUTH -u AXONFLOW_MCP_AUTHORIZATION \
  HOME="$WORK/home" AXONFLOW_CONFIG_DIR="$AXONFLOW_CONFIG_DIR" AXONFLOW_TELEMETRY=off \
  PATH="$WORK/bin:$PATH" AXONFLOW_E2E_REAL_CURL="$REAL_CURL" \
  AXONFLOW_E2E_AGENT_ORIGIN="$AXONFLOW_HOSTED_E2E_ENDPOINT" \
  AXONFLOW_E2E_DECISION_FILE="$WORK/hook.decision" \
  bash -c 'source "$1"; printf "%s\n" "$3" | bash "$2"' _ \
    "$ROOT/scripts/hosted-env.sh" "$ROOT/scripts/pre-tool-check.sh" "$HOOK_INPUT" \
  >"$WORK/hook.out" 2>"$WORK/hook.err"
grep -Fq 'Connected to AxonFlow at https://try-staging.getaxonflow.com (mode=community-saas)' "$WORK/hook.err"
if ! observed_allow "$WORK/hook.decision"; then
  echo 'FAIL: the hook did not observe an HTTP 200 Agent check_policy allow decision' >&2
  exit 1
fi
if grep -Eqi 'governance blocked|auth error|unauthorized' "$WORK/hook.err"; then
  echo 'FAIL: linked staging hook reported a governance/auth error' >&2
  exit 1
fi
if grep -Eqi '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"|governance.*(blocked|auth)' "$WORK/hook.out"; then
  echo 'FAIL: linked staging hook denied the benign probe' >&2
  exit 1
fi

# Prove the editor MCP setup uses the same linked endpoint and credential,
# then obtain a second decision from the Agent MCP route.
jq -e '.mcpServers.axonflow.url == "${AXONFLOW_ENDPOINT:-http://localhost:8080}/api/v1/mcp-server" and (.mcpServers.axonflow.headersHelper | contains("AXONFLOW_AUTH"))' "$ROOT/.mcp.json" >/dev/null
(
  unset AXONFLOW_ENDPOINT AXONFLOW_AUTH AXONFLOW_MCP_AUTHORIZATION AXONFLOW_CLIENT_HEADER
  export HOME="$WORK/home" AXONFLOW_CONFIG_DIR
  # shellcheck disable=SC1091
  . "$ROOT/scripts/hosted-env.sh"
  # shellcheck disable=SC1091
  . "$ROOT/scripts/client-header.sh"
  test "$AXONFLOW_ENDPOINT" = "$AXONFLOW_HOSTED_E2E_ENDPOINT"
  test "$AXONFLOW_MCP_AUTHORIZATION" = "Basic $AXONFLOW_AUTH"
  mcp_headers=$(sh -c "$(jq -r '.mcpServers.axonflow.headersHelper' "$ROOT/.mcp.json")")
  mcp_auth=$(printf '%s' "$mcp_headers" | jq -r '.Authorization // empty')
  mcp_client=$(printf '%s' "$mcp_headers" | jq -r '."X-Axonflow-Client" // empty')
  test "$mcp_auth" = "$AXONFLOW_MCP_AUTHORIZATION"
  test "$mcp_client" = "$AXONFLOW_CLIENT_HEADER"
  mcp_code=$("$REAL_CURL" -sS --max-time 8 -o "$WORK/mcp.body" -w '%{http_code}' \
    -X POST "$AXONFLOW_ENDPOINT/api/v1/mcp-server" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -H "Authorization: $mcp_auth" \
    -H "X-Axonflow-Client: $mcp_client" \
    -d '{"jsonrpc":"2.0","id":"mcp-proof","method":"tools/call","params":{"name":"check_policy","arguments":{"connector_type":"claude_code.Bash","statement":"echo axonflow-hosted-link-probe","operation":"execute"}}}')
  test "$mcp_code" = 200
  jq -e '.jsonrpc == "2.0" and .id == "mcp-proof" and .result.isError != true and (.result.content[0].text | fromjson | .allowed == true)' "$WORK/mcp.body" >/dev/null
)

# Force a real transport failure for the same Agent origin. The production
# hook may fail open; the release proof must still reject its missing decision.
env -u AXONFLOW_ENDPOINT -u AXONFLOW_AUTH -u AXONFLOW_MCP_AUTHORIZATION \
  HOME="$WORK/home" AXONFLOW_CONFIG_DIR="$AXONFLOW_CONFIG_DIR" AXONFLOW_TELEMETRY=off \
  PATH="$WORK/bin:$PATH" AXONFLOW_E2E_REAL_CURL="$REAL_CURL" \
  AXONFLOW_E2E_AGENT_ORIGIN="$AXONFLOW_HOSTED_E2E_ENDPOINT" \
  AXONFLOW_E2E_DECISION_FILE="$WORK/transport.decision" \
  AXONFLOW_E2E_TRANSPORT_FILE="$WORK/transport.error" \
  HTTPS_PROXY=http://127.0.0.1:1 https_proxy=http://127.0.0.1:1 \
  ALL_PROXY= all_proxy= NO_PROXY= no_proxy= \
  bash -c 'source "$1"; printf "%s\n" "$3" | bash "$2"' _ \
    "$ROOT/scripts/hosted-env.sh" "$ROOT/scripts/pre-tool-check.sh" "$HOOK_INPUT" \
  >"$WORK/transport.out" 2>"$WORK/transport.err"
test -s "$WORK/transport.error"
if observed_allow "$WORK/transport.decision"; then
  echo 'FAIL: a transport failure satisfied the Agent-decision proof' >&2
  exit 1
fi
echo 'PASS: approved device link, protected credential, observed hook and MCP decisions; transport failure rejected'
