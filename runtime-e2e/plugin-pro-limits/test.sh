#!/usr/bin/env bash
# Plugin Pro v1 — free-tier active-custom-policy cap (MCP tool path).
#
# The `v1_pro_graduated_freemium` capability gates the
# `axonflow_create_tenant_policy` MCP tool at FreeLimits.MaxActiveCustomPolicies=2
# active policies; ProLimits.MaxActiveCustomPolicies=-1 (unlimited).
# Plugins call this tool via /api/v1/mcp-server; the direct
# /api/v1/dynamic-policies REST endpoint does NOT enforce this cap
# (it's a plugin-runtime gate by design).
#
# This test does NOT yet exercise the Pro-token unlock path — needs a
# real plugin_user_licenses DB row, normally seeded by the Stripe
# webhook flow. See plugin-pro-limits-with-token (follow-on).

set -uo pipefail

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"

echo "=== Plugin Pro v1 — free-tier MaxActiveCustomPolicies=2 cap (MCP tool) ==="
echo "Endpoint: $ENDPOINT"

if ! curl -sSf -o /dev/null --max-time 5 "$ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $ENDPOINT"
  exit 0
fi

REG_LABEL="plugin-pro-cap-mcp-$(date +%s)-$RANDOM"
REG=$(curl -s -X POST "$ENDPOINT/api/v1/register" \
  -H "Content-Type: application/json" \
  -d "{\"label\":\"$REG_LABEL\",\"email\":\"$REG_LABEL@axonflow-test.invalid\"}")
TENANT_ID=$(echo "$REG" | jq -r '.tenant_id // empty')
SECRET=$(echo "$REG" | jq -r '.secret // empty')
[ -z "$TENANT_ID" ] || [ -z "$SECRET" ] && { echo "FAIL: register did not return creds. body: $REG"; exit 1; }
echo "PASS: registered free-tier tenant $TENANT_ID"

AUTH="Basic $(printf '%s:%s' "$TENANT_ID" "$SECRET" | base64 | tr -d '\n')"

INIT=$(curl -s -X POST "$ENDPOINT/api/v1/mcp-server" \
  -H "Authorization: $AUTH" -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -D /tmp/_pro_init.hdr \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"plugin-pro-cap-test","version":"1.0"}}}')
SID=$(grep -i 'Mcp-Session-Id' /tmp/_pro_init.hdr | tr -d '\r' | awk -F': ' '{print $2}')
[ -z "$SID" ] && { echo "FAIL: initialize returned no session id"; exit 1; }
echo "PASS: MCP session $SID"

call_create() {
  local idx="$1"
  curl -s -o /tmp/_pro_body.json -w "%{http_code}" -X POST "$ENDPOINT/api/v1/mcp-server" \
    -H "Authorization: $AUTH" -H "Content-Type: application/json" \
    -H "Mcp-Session-Id: $SID" -H "MCP-Protocol-Version: 2025-06-18" \
    -d "{
      \"jsonrpc\":\"2.0\",
      \"id\":$((idx + 10)),
      \"method\":\"tools/call\",
      \"params\":{
        \"name\":\"axonflow_create_tenant_policy\",
        \"arguments\":{
          \"name\":\"plugin-pro-cap-mcp-$idx\",
          \"description\":\"Pro cap MCP test $idx\",
          \"connector_type\":\"claude_code.Bash\",
          \"pattern\":\"rm -rf /test-marker-$idx\",
          \"action\":\"block\"
        }
      }
    }"
}

result_is_error_for() { echo "$1" | jq -e '.result.isError == true' >/dev/null 2>&1; }

S1=$(call_create 1); B1=$(cat /tmp/_pro_body.json)
S2=$(call_create 2); B2=$(cat /tmp/_pro_body.json)
echo "  policy 1: HTTP $S1 isError=$(echo "$B1" | jq -r '.result.isError // false')"
echo "  policy 2: HTTP $S2 isError=$(echo "$B2" | jq -r '.result.isError // false')"
if result_is_error_for "$B1" || result_is_error_for "$B2"; then
  echo "FAIL: first 2 MCP policy creations should succeed"
  echo "  b1: $B1"
  echo "  b2: $B2"
  exit 1
fi
echo "PASS: 2 active custom policies created at cap (via MCP tool)"

S3=$(call_create 3); B3=$(cat /tmp/_pro_body.json)
echo "  policy 3: HTTP $S3 isError=$(echo "$B3" | jq -r '.result.isError // false')"
if ! result_is_error_for "$B3"; then
  echo "FAIL: 3rd MCP policy create should be rejected (FreeLimits.MaxActiveCustomPolicies=2)"
  echo "  b3: $B3"
  exit 1
fi
ERR_TEXT=$(echo "$B3" | jq -r '.result.content[]? | select(.type=="text") | .text // empty' 2>/dev/null)
if echo "$ERR_TEXT" | grep -qiE 'upgrade|Pro|limit|cap|policy.*2'; then
  echo "PASS: 3rd policy rejected with upgrade-aware error: $ERR_TEXT"
else
  echo "FAIL: 3rd policy rejected but error message lacks upgrade context (need cap-specific wording for the user-facing envelope)"
  echo "      got: $ERR_TEXT"
  exit 1
fi

echo
echo "=== Plugin Pro v1 free-tier MCP-tool cap test: PASS ==="
echo "Behavior validated:"
echo "  - 2 custom policies pass via axonflow_create_tenant_policy"
echo "  - 3rd is rejected with isError=true"
echo "  - Error message points at the Pro upgrade path"
