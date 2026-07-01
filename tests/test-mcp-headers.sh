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

# ---------------------------------------------------------------------------
# axonflow-claude-plugin#94 regression coverage.
#
# Root cause: against a self-hosted/Enterprise agent (AXONFLOW_ENDPOINT set to a
# non-try host) with AXONFLOW_AUTH unset, the inline helper fell back to the
# Community-SaaS try-registration.json and sent a cs_<uuid> credential. The
# Enterprise agent rejected it ("invalid license key prefix (expected AXON-)")
# → HTTP 401 → `/mcp` showed "axonflow failed". The fixes below MUST hold.
# ---------------------------------------------------------------------------
ENT_EP='http://axonflow.internal:8080'

# 7) THE #94 fix: Enterprise endpoint + stale cs_ try-registration.json + no
#    auth → the cs_ credential MUST NOT be sent (no Authorization at all).
#    Proven red-on-revert: an ungated cs_ fallback emits "Basic base64(cs_...)".
TMPHOME="$(mktemp -d)"
mkdir -p "$TMPHOME/.config/axonflow"
printf '%s' '{"tenant_id":"cs_stale","secret":"sekret"}' > "$TMPHOME/.config/axonflow/try-registration.json"
OUT="$(env -u AXONFLOW_AUTH HOME="$TMPHOME" AXONFLOW_ENDPOINT="$ENT_EP" /bin/sh -c "cd / && $HH")"
if printf '%s' "$OUT" | jq -e 'has("Authorization")|not' >/dev/null 2>&1; then
  echo "PASS: Enterprise endpoint + stale cs_ registration → no cross-deployment Authorization leak"
else
  echo "FAIL: Enterprise endpoint leaked a Community-SaaS cs_ credential: $OUT"; fail=1
fi
rm -rf "$TMPHOME"

# 8) Durable Enterprise fallback: Enterprise endpoint + self-hosted-auth.json
#    (0600) + no auth → Authorization from the file's base64 .auth value.
TMPHOME="$(mktemp -d)"
mkdir -p "$TMPHOME/.config/axonflow"
SH_AUTH="$(printf 'acme:AXON-key' | base64 | tr -d '\n')"
printf '{"org_id":"acme","license_key":"AXON-key","auth":"%s"}' "$SH_AUTH" > "$TMPHOME/.config/axonflow/self-hosted-auth.json"
chmod 600 "$TMPHOME/.config/axonflow/self-hosted-auth.json"
OUT="$(env -u AXONFLOW_AUTH HOME="$TMPHOME" AXONFLOW_ENDPOINT="$ENT_EP" /bin/sh -c "cd / && $HH")"
if [ "$(printf '%s' "$OUT" | jq -r '.Authorization // empty')" = "Basic $SH_AUTH" ]; then
  echo "PASS: Enterprise endpoint + self-hosted-auth.json(0600) → Authorization from file"
else
  echo "FAIL: self-hosted-auth.json fallback wrong: $OUT"; fail=1
fi

# 9) Security posture: self-hosted-auth.json with loose perms → refused.
chmod 644 "$TMPHOME/.config/axonflow/self-hosted-auth.json"
OUT="$(env -u AXONFLOW_AUTH HOME="$TMPHOME" AXONFLOW_ENDPOINT="$ENT_EP" /bin/sh -c "cd / && $HH" 2>/dev/null)"
if printf '%s' "$OUT" | jq -e 'has("Authorization")|not' >/dev/null 2>&1; then
  echo "PASS: self-hosted-auth.json with unsafe perms (0644) → refused (no Authorization)"
else
  echo "FAIL: loose-perm self-hosted-auth.json was used: $OUT"; fail=1
fi
rm -rf "$TMPHOME"

# 10) base64 normalization: a raw "<org>:<key>" AXONFLOW_AUTH (a common
#     misconfig that 401s as "Basic <raw>") is coerced to base64.
OUT="$(HOME=/nonexistent-empty-home AXONFLOW_ENDPOINT="$ENT_EP" AXONFLOW_AUTH='rawid:rawsecret' /bin/sh -c "cd / && $HH")"
EXPECT="Basic $(printf 'rawid:rawsecret' | base64 | tr -d '\n')"
if [ "$(printf '%s' "$OUT" | jq -r '.Authorization // empty')" = "$EXPECT" ]; then
  echo "PASS: raw <org>:<key> AXONFLOW_AUTH normalized to base64"
else
  echo "FAIL: raw AXONFLOW_AUTH not normalized: $OUT"; fail=1
fi

# 11) Precedence: env AXONFLOW_AUTH wins over the self-hosted-auth.json file.
TMPHOME="$(mktemp -d)"
mkdir -p "$TMPHOME/.config/axonflow"
printf '{"org_id":"file","license_key":"k","auth":"%s"}' "$(printf 'file:k'|base64|tr -d '\n')" > "$TMPHOME/.config/axonflow/self-hosted-auth.json"
chmod 600 "$TMPHOME/.config/axonflow/self-hosted-auth.json"
ENVB64="$(printf 'envwins:s' | base64 | tr -d '\n')"
OUT="$(HOME="$TMPHOME" AXONFLOW_ENDPOINT="$ENT_EP" AXONFLOW_AUTH="$ENVB64" /bin/sh -c "cd / && $HH")"
if [ "$(printf '%s' "$OUT" | jq -r '.Authorization // empty')" = "Basic $ENVB64" ]; then
  echo "PASS: env AXONFLOW_AUTH takes precedence over self-hosted-auth.json"
else
  echo "FAIL: env did not win over file: $OUT"; fail=1
fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# Per-developer identity (issue #2754): the headersHelper must emit X-User-Email
# when AXONFLOW_USER_EMAIL is set, omit it cleanly when unset, and never let a
# CR/LF-laden value split the header object.
# ---------------------------------------------------------------------------

# 12) env AXONFLOW_USER_EMAIL → X-User-Email in the emitted object.
OUT="$(HOME=/nonexistent-empty-home AXONFLOW_USER_EMAIL='alice@example.com' AXONFLOW_AUTH='dGVzdA==' run_hh)"
if [ "$(printf '%s' "$OUT" | jq -r '."X-User-Email" // empty')" = "alice@example.com" ]; then
  echo "PASS: AXONFLOW_USER_EMAIL → X-User-Email header"
else
  echo "FAIL: X-User-Email not emitted from AXONFLOW_USER_EMAIL: $OUT"; fail=1
fi

# 13) no identity (empty HOME, cwd / so no repo-local git email) → X-User-Email
#     is ABSENT (never an empty header). Runs from / to avoid picking up this
#     repo's own git identity.
OUT="$(env -u AXONFLOW_USER_EMAIL HOME=/nonexistent-empty-home /bin/sh -c "cd / && $HH")"
if printf '%s' "$OUT" | jq -e 'has("X-User-Email")|not' >/dev/null 2>&1; then
  echo "PASS: no identity → X-User-Email omitted"
else
  echo "FAIL: X-User-Email present with no identity configured: $OUT"; fail=1
fi

# 14) header-split guard: a CR/LF-laden value must be stripped and the output
#     must still be a single valid JSON object.
OUT="$(HOME=/nonexistent-empty-home AXONFLOW_USER_EMAIL="$(printf 'bob@x.com\r\nEvil: hdr')" AXONFLOW_AUTH='dGVzdA==' run_hh)"
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
   && [ "$(printf '%s' "$OUT" | jq -r '."X-User-Email" // empty')" = "bob@x.comEvil:hdr" ]; then
  echo "PASS: CR/LF in AXONFLOW_USER_EMAIL stripped (no header split, valid JSON)"
else
  echo "FAIL: CR/LF sanitization failed: $OUT"; fail=1
fi

# 15) JSON-safety guard: a double-quote / backslash in the email (invalid, but
#     an operator could set it) must be stripped so the emitted header object
#     stays valid JSON — Claude Code rejects a malformed value for the whole
#     session.
OUT="$(HOME=/nonexistent-empty-home AXONFLOW_USER_EMAIL='a"b\c@x.com' AXONFLOW_AUTH='dGVzdA==' run_hh)"
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
   && [ "$(printf '%s' "$OUT" | jq -r '."X-User-Email" // empty')" = "abc@x.com" ]; then
  echo "PASS: quote/backslash in AXONFLOW_USER_EMAIL stripped (JSON stays valid)"
else
  echo "FAIL: quote/backslash not sanitized, JSON may be broken: $OUT"; fail=1
fi

echo ""
if [ "$fail" -ne 0 ]; then
  echo "FAIL: .mcp.json headersHelper unit test"
  exit 1
fi
echo "PASS: .mcp.json headersHelper unit test"
