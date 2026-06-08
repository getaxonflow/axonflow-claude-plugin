#!/usr/bin/env bash
# Unit test for the .mcp.json `headersHelper` — the MCP-server auth header
# generator.
#
# Regression context: the plugin originally shipped
#   "headersHelper": "${CLAUDE_PLUGIN_ROOT}/scripts/mcp-auth-headers.sh"
# but Claude Code does NOT expand ${CLAUDE_PLUGIN_ROOT} (or any env var) in the
# headersHelper field (it only expands command/args/env/url/headers). The
# helper therefore never ran, no Authorization header was sent, and the MCP
# connection collapsed into OAuth discovery + the agent's plaintext
# "404 page not found" → `/mcp` showed "axonflow failed". The fix inlines a
# self-contained, path-independent resolver. This test locks that in.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MCP_JSON="$ROOT/.mcp.json"
fail=0

echo "== .mcp.json headersHelper unit test =="

# 1) Valid JSON.
if jq -e . "$MCP_JSON" >/dev/null 2>&1; then
  echo "PASS: .mcp.json is valid JSON"
else
  echo "FAIL: .mcp.json is not valid JSON"; fail=1
fi

HH="$(jq -r '.mcpServers.axonflow.headersHelper // empty' "$MCP_JSON")"
URL="$(jq -r '.mcpServers.axonflow.url // empty' "$MCP_JSON")"

# 2) The url MUST still use ${AXONFLOW_ENDPOINT} (env expansion IS supported there).
if printf '%s' "$URL" | grep -q 'AXONFLOW_ENDPOINT'; then
  echo "PASS: url honors \${AXONFLOW_ENDPOINT}"
else
  echo "FAIL: url no longer references \${AXONFLOW_ENDPOINT}: $URL"; fail=1
fi

# 3) THE regression guard: headersHelper must NOT depend on ${CLAUDE_PLUGIN_ROOT}
#    (unexpanded there) or any plugin-relative path.
if [ -z "$HH" ]; then
  echo "FAIL: headersHelper missing from .mcp.json"; fail=1
elif printf '%s' "$HH" | grep -q 'CLAUDE_PLUGIN_ROOT'; then
  echo "FAIL: headersHelper references \${CLAUDE_PLUGIN_ROOT} — Claude Code will not expand it (the original bug)"; fail=1
else
  echo "PASS: headersHelper is path-independent (no \${CLAUDE_PLUGIN_ROOT})"
fi

# Helper to run the inline headersHelper exactly as Claude Code would: via a
# shell, with a controlled HOME + env.
run_hh() { ( cd / && /bin/sh -c "$HH" ); }

# 4) env AXONFLOW_AUTH present → emits a valid JSON object with Authorization.
OUT="$(HOME=/nonexistent-empty-home AXONFLOW_AUTH='dGVzdGF1dGg=' run_hh)"
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  if [ "$(printf '%s' "$OUT" | jq -r '.Authorization // empty')" = "Basic dGVzdGF1dGg=" ]; then
    echo "PASS: env AXONFLOW_AUTH → Authorization: Basic <auth>"
  else
    echo "FAIL: env AXONFLOW_AUTH did not produce the expected Authorization header: $OUT"; fail=1
  fi
else
  echo "FAIL: headersHelper did not emit valid JSON with env auth: $OUT"; fail=1
fi

# 5) Community fallback: no env auth, but a try-registration.json on disk →
#    Authorization derived from base64(tenant_id:secret).
TMPHOME="$(mktemp -d)"
mkdir -p "$TMPHOME/.config/axonflow"
printf '%s' '{"tenant_id":"cs_unit","secret":"sekret"}' > "$TMPHOME/.config/axonflow/try-registration.json"
OUT="$(env -u AXONFLOW_AUTH HOME="$TMPHOME" /bin/sh -c "cd / && $HH")"
EXPECT_AUTH="Basic $(printf 'cs_unit:sekret' | base64 | tr -d '\n')"
if [ "$(printf '%s' "$OUT" | jq -r '.Authorization // empty')" = "$EXPECT_AUTH" ]; then
  echo "PASS: community try-registration.json → Authorization from base64(tenant:secret)"
else
  echo "FAIL: community fallback wrong. got=$(printf '%s' "$OUT" | jq -r '.Authorization // empty') want=$EXPECT_AUTH"; fail=1
fi
rm -rf "$TMPHOME"

# 6) No credential anywhere → still valid JSON (X-Axonflow-Client only); the
#    helper must never emit a partial / unparseable value (which Claude Code
#    rejects as "did not return a valid value").
OUT="$(env -u AXONFLOW_AUTH HOME=/nonexistent-empty-home /bin/sh -c "cd / && $HH")"
if printf '%s' "$OUT" | jq -e 'has("X-Axonflow-Client") and (has("Authorization")|not)' >/dev/null 2>&1; then
  echo "PASS: no credential → valid JSON with only X-Axonflow-Client"
else
  echo "FAIL: no-credential output is not the expected valid JSON: $OUT"; fail=1
fi

echo ""
if [ "$fail" -ne 0 ]; then
  echo "FAIL: .mcp.json headersHelper unit test"
  exit 1
fi
echo "PASS: .mcp.json headersHelper unit test"
