#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="${AXONFLOW_TEST_PLUGIN_ROOT:-$(cd "$TEST_DIR/.." && pwd)}"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME" AXONFLOW_TELEMETRY=off
export AXONFLOW_CONFIG_DIR="$TEST_HOME/.config/axonflow"
unset AXONFLOW_ENDPOINT AXONFLOW_AUTH AXONFLOW_MCP_AUTHORIZATION

# A fresh hook may tell the user where to start, but cannot create a tenant.
AXONFLOW_MODE=community-saas bash -c '. "$1"; test -z "${AXONFLOW_AUTH:-}"' _ "$PLUGIN_DIR/scripts/community-saas-bootstrap.sh"
test ! -e "$HOME/.config/axonflow/try-registration.json"
printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' | bash "$PLUGIN_DIR/scripts/pre-tool-check.sh" >"$TEST_HOME/cold.out" 2>"$TEST_HOME/cold.err"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("https://portal.try.getaxonflow.com/hosted/start"))' "$TEST_HOME/cold.out" >/dev/null
env PATH=/nonexistent HOME="$TEST_HOME" /bin/bash "$PLUGIN_DIR/scripts/pre-tool-check.sh" </dev/null >"$TEST_HOME/no-deps.out" 2>"$TEST_HOME/no-deps.err"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("install jq and curl"))' "$TEST_HOME/no-deps.out" >/dev/null

export AXONFLOW_LINK_HARNESS=1
export AXONFLOW_LINK_FETCH_LOG="$TEST_HOME/fetch.log"
NODE_OPTIONS="--import=$TEST_DIR/hosted-link-fetch.mjs" node "$PLUGIN_DIR/scripts/hosted-link.mjs" >"$TEST_HOME/link.out"
file="$HOME/.config/axonflow/hosted-claude-code.json"
file_mode=$(stat -c %a "$file" 2>/dev/null) || file_mode=""
case "$file_mode" in ''|*[!0-9]*) file_mode=$(stat -f %Lp "$file" 2>/dev/null) || file_mode="" ;; esac
test "$file_mode" = 600
jq -e '.tenant_id == "cs_12345678-1234-1234-1234-123456789abc" and .link_method == "portal-device" and .endpoint == "https://try.getaxonflow.com" and (.secret | test("^[0-9a-f]{64}$"))' "$file" >/dev/null
test "$(cat "$AXONFLOW_LINK_FETCH_LOG")" = "$(printf 'start\npoll')"
secret=$(jq -r .secret "$file")
if rg -q "$secret" "$TEST_HOME/link.out"; then
  echo 'FAIL: link command printed the reusable secret' >&2
  exit 1
fi
test "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$(NODE_OPTIONS="--import=$TEST_DIR/hosted-link-fetch.mjs" node "$PLUGIN_DIR/scripts/hosted-link.mjs" >/dev/null 2>&1 || true; shasum -a 256 "$file" | cut -d' ' -f1)"
test "$(cat "$AXONFLOW_LINK_FETCH_LOG")" = "$(printf 'start\npoll')"

# Cached credentials and explicit user config remain intact.
AXONFLOW_MODE=community-saas bash -c '. "$1"; test -n "${AXONFLOW_AUTH:-}"' _ "$PLUGIN_DIR/scripts/community-saas-bootstrap.sh"
AXONFLOW_MODE=self-hosted AXONFLOW_AUTH=existing bash -c '. "$1"; test "$AXONFLOW_AUTH" = existing' _ "$PLUGIN_DIR/scripts/community-saas-bootstrap.sh"
bash -c 'source "$1"; test "$AXONFLOW_ENDPOINT" = https://try.getaxonflow.com; test "$AXONFLOW_MCP_AUTHORIZATION" = "Basic $AXONFLOW_AUTH"' _ "$PLUGIN_DIR/scripts/hosted-env.sh"
AXONFLOW_AUTH=existing bash -c 'source "$1" >/dev/null 2>&1 && exit 1; test "$AXONFLOW_AUTH" = existing' _ "$PLUGIN_DIR/scripts/hosted-env.sh"
AXONFLOW_MCP_AUTHORIZATION=existing bash -c 'source "$1" >/dev/null 2>&1 && exit 1; test "$AXONFLOW_MCP_AUTHORIZATION" = existing' _ "$PLUGIN_DIR/scripts/hosted-env.sh"

# A plugin link takes precedence only for this plugin. The old shared file
# stays usable when no plugin-specific link exists.
headers=$(bash "$PLUGIN_DIR/scripts/mcp-auth-headers.sh" 2>/dev/null)
printf '%s' "$headers" | jq -e 'has("Authorization") | not' >/dev/null
legacy="$HOME/.config/axonflow/try-registration.json"
printf '%s' '{"tenant_id":"cs_legacy","secret":"legacy-secret","expires_at":"2099-01-01T00:00:00Z"}' > "$legacy"
chmod 0600 "$legacy"
linked_auth=$(printf '%s:%s' "$(jq -r .tenant_id "$file")" "$(jq -r .secret "$file")" | base64 | tr -d '\n')
AXONFLOW_MODE=community-saas EXPECTED_AUTH="$linked_auth" bash -c '. "$1"; test "$AXONFLOW_AUTH" = "$EXPECTED_AUTH"' _ "$PLUGIN_DIR/scripts/community-saas-bootstrap.sh"
mv "$file" "$file.saved"
legacy_auth=$(printf '%s' 'cs_legacy:legacy-secret' | base64 | tr -d '\n')
AXONFLOW_MODE=community-saas EXPECTED_AUTH="$legacy_auth" bash -c '. "$1"; test "$AXONFLOW_AUTH" = "$EXPECTED_AUTH"' _ "$PLUGIN_DIR/scripts/community-saas-bootstrap.sh"
mv "$file.saved" "$file"
chmod 0644 "$file"
AXONFLOW_MODE=community-saas bash -c '. "$1"; test -z "${AXONFLOW_AUTH:-}"' _ "$PLUGIN_DIR/scripts/community-saas-bootstrap.sh" 2>"$TEST_HOME/unsafe.err"
rg -q 'unsafe permissions' "$TEST_HOME/unsafe.err"
chmod 0600 "$file"

echo 'PASS: Hosted device link, protected persistence, precedence, and cold setup'
