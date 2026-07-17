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
if printf '%s' "$OUT" | jq -e 'has("X-Axonflow-Client") and (."X-Axonflow-Client" | test("^claude-code-plugin/[0-9]")) and (has("Authorization")|not)' >/dev/null 2>&1; then
  echo "PASS: no credential → valid JSON with only a VERSIONED X-Axonflow-Client"
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

# ---------------------------------------------------------------------------
# #2836 identity-absent hardening — the inline resolver must match
# scripts/user-identity.sh semantics (sanitize-first fall-through, merged →
# --global git read). These pin the inline port; the bash impl is covered by
# tests/test-user-identity.sh.
# ---------------------------------------------------------------------------

# 16) blank (whitespace-only) AXONFLOW_USER_EMAIL falls through to the git
#     fallback instead of silently suppressing the header. Global git identity
#     injected deterministically via GIT_CONFIG_GLOBAL.
GCFG="$(mktemp)"
printf '[user]\n\temail = glob@example.com\n' > "$GCFG"
OUT="$(env -u AXONFLOW_AUTH HOME=/nonexistent-empty-home AXONFLOW_USER_EMAIL='   ' \
  GIT_CONFIG_GLOBAL="$GCFG" GIT_CONFIG_SYSTEM=/dev/null /bin/sh -c "cd / && $HH")"
if [ "$(printf '%s' "$OUT" | jq -r '."X-User-Email" // empty')" = "glob@example.com" ]; then
  echo "PASS: blank AXONFLOW_USER_EMAIL falls through to the git fallback"
else
  echo "FAIL: blank AXONFLOW_USER_EMAIL did not fall through: $OUT"; fail=1
fi

# 17) corrupt .git/config cwd → the merged read dies, the explicit --global
#     read still recovers the identity (the #2836 broken-repo class).
BROKEN="$(mktemp -d)"
git -C "$BROKEN" init -q >/dev/null 2>&1 || true
printf '[user\n' > "$BROKEN/.git/config"   # unclosed section → fatal: bad config
OUT="$(env -u AXONFLOW_AUTH -u AXONFLOW_USER_EMAIL HOME=/nonexistent-empty-home \
  GIT_CONFIG_GLOBAL="$GCFG" GIT_CONFIG_SYSTEM=/dev/null /bin/sh -c "cd '$BROKEN' && $HH")"
if [ "$(printf '%s' "$OUT" | jq -r '."X-User-Email" // empty')" = "glob@example.com" ]; then
  echo "PASS: corrupt .git/config cwd → --global read recovers the identity"
else
  echo "FAIL: corrupt-repo cwd lost the identity: $OUT"; fail=1
fi
rm -rf "$BROKEN" "$GCFG"

# ---------------------------------------------------------------------------
# #2842 control-byte sanitization — the inline assembles the headers JSON with
# printf (not jq), so any C0 control byte surviving sanitization lands raw
# inside the JSON string and Claude Code rejects the whole headers value → the
# axonflow MCP connection breaks. The inline is the REAL MCP surface: these
# drive it from inside a repo whose repo-local user.email carries the bytes.
# ---------------------------------------------------------------------------

# 18) FF (0x0c) + VT (0x0b) + DEL (0x7f) in the repo-local user.email — all
#     survive git reads (verified) and previously survived sanitization.
#     Output must be VALID JSON with the control bytes removed.
#     Red-on-revert with the pre-#2842 tr set ' \t\r\n"\\'.
CTRL_REPO="$(mktemp -d)"
git -C "$CTRL_REPO" init -q >/dev/null 2>&1 || true
printf '[user]\n\temail = ceo@x.com\x0cF\x0bV\x7fD\n' > "$CTRL_REPO/.git/config"
OUT="$(env -u AXONFLOW_AUTH -u AXONFLOW_USER_EMAIL HOME=/nonexistent-empty-home \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null /bin/sh -c "cd '$CTRL_REPO' && $HH")"
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
   && [ "$(printf '%s' "$OUT" | jq -r '."X-User-Email" // empty')" = "ceo@x.comFVD" ]; then
  echo "PASS: control bytes in repo-local user.email stripped, headers JSON stays valid"
else
  echo "FAIL: control-byte email broke the headers JSON or survived: $(printf '%q' "$OUT")"; fail=1
fi
rm -rf "$CTRL_REPO"

# 19) NUL (0x00) in the repo-local user.email — git itself truncates the
#     value at the NUL (verified) and command substitution drops NUL bytes,
#     so the byte can never reach the JSON; pin that the output is valid and
#     carries the truncated address.
NUL_REPO="$(mktemp -d)"
git -C "$NUL_REPO" init -q >/dev/null 2>&1 || true
printf '[user]\n\temail = ceo@x.com\x00N\n' > "$NUL_REPO/.git/config"
OUT="$(env -u AXONFLOW_AUTH -u AXONFLOW_USER_EMAIL HOME=/nonexistent-empty-home \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null /bin/sh -c "cd '$NUL_REPO' && $HH")"
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
   && [ "$(printf '%s' "$OUT" | jq -r '."X-User-Email" // empty')" = "ceo@x.com" ]; then
  echo "PASS: NUL in repo-local user.email → git-truncated value, headers JSON stays valid"
else
  echo "FAIL: NUL-bearing email broke the headers JSON: $(printf '%q' "$OUT")"; fail=1
fi
rm -rf "$NUL_REPO"

# ---------------------------------------------------------------------------
# Per-user authorization token (axonflow-enterprise#2935, epic #2919): the
# inline must emit X-User-Token when a token is configured (env
# AXONFLOW_USER_TOKEN wins → 0600-guarded ~/.config/axonflow/user-token.json),
# omit it entirely when not (byte-identical output — never an empty header),
# and DROP a wire-unsafe candidate rather than mangle-and-send it (the
# platform fails closed on a presented-but-invalid token). The bash reference
# impl (scripts/user-token.sh + mcp-auth-headers.sh) is pinned by
# tests/test-user-token.sh; these pin the inline port.
# ---------------------------------------------------------------------------
UT_GOOD='eyJhbGciOiJIUzI1NiJ9.eyJlbWFpbCI6ImRldkB4LmNvIn0.sig-_123'

# 20) env AXONFLOW_USER_TOKEN → X-User-Token in the emitted object.
OUT="$(HOME=/nonexistent-empty-home AXONFLOW_AUTH='dGVzdA==' AXONFLOW_USER_EMAIL='alice@example.com' AXONFLOW_USER_TOKEN="$UT_GOOD" run_hh)"
if [ "$(printf '%s' "$OUT" | jq -r '."X-User-Token" // empty')" = "$UT_GOOD" ]; then
  echo "PASS: AXONFLOW_USER_TOKEN → X-User-Token header"
else
  echo "FAIL: X-User-Token not emitted from AXONFLOW_USER_TOKEN: $OUT"; fail=1
fi

# 21) unconfigured (the common fleet state) → output is BYTE-IDENTICAL to the
#     configured run minus the X-User-Token member — proves strictly-additive
#     (no empty header, no reordering, no other drift).
BASE="$(HOME=/nonexistent-empty-home AXONFLOW_AUTH='dGVzdA==' AXONFLOW_USER_EMAIL='alice@example.com' run_hh)"
CONFIGURED_MINUS_TOKEN="$(HOME=/nonexistent-empty-home AXONFLOW_AUTH='dGVzdA==' AXONFLOW_USER_EMAIL='alice@example.com' AXONFLOW_USER_TOKEN="$UT_GOOD" run_hh | sed "s/,\"X-User-Token\":\"$UT_GOOD\"//")"
if printf '%s' "$BASE" | jq -e 'has("X-User-Token")|not' >/dev/null 2>&1 \
   && [ "$BASE" = "$CONFIGURED_MINUS_TOKEN" ]; then
  echo "PASS: no token → X-User-Token omitted; output byte-identical modulo the token member"
else
  echo "FAIL: unconfigured output drifted: base=$BASE configured-minus-token=$CONFIGURED_MINUS_TOKEN"; fail=1
fi

# 22) file fallback: 0600 user-token.json loads; env wins over it.
TMPHOME="$(mktemp -d)"
mkdir -p "$TMPHOME/.config/axonflow"
printf '{"token":"file.tok.value"}' > "$TMPHOME/.config/axonflow/user-token.json"
chmod 600 "$TMPHOME/.config/axonflow/user-token.json"
OUT="$(env -u AXONFLOW_USER_TOKEN HOME="$TMPHOME" AXONFLOW_AUTH='dGVzdA==' /bin/sh -c "cd / && $HH")"
if [ "$(printf '%s' "$OUT" | jq -r '."X-User-Token" // empty')" = "file.tok.value" ]; then
  echo "PASS: 0600 user-token.json → X-User-Token from file"
else
  echo "FAIL: 0600 user-token.json not loaded: $OUT"; fail=1
fi
OUT="$(HOME="$TMPHOME" AXONFLOW_AUTH='dGVzdA==' AXONFLOW_USER_TOKEN="$UT_GOOD" /bin/sh -c "cd / && $HH")"
if [ "$(printf '%s' "$OUT" | jq -r '."X-User-Token" // empty')" = "$UT_GOOD" ]; then
  echo "PASS: env AXONFLOW_USER_TOKEN wins over user-token.json"
else
  echo "FAIL: file token overrode the env token: $OUT"; fail=1
fi

# 23) security posture: user-token.json with loose perms (0644) → refused.
chmod 644 "$TMPHOME/.config/axonflow/user-token.json"
OUT="$(env -u AXONFLOW_USER_TOKEN HOME="$TMPHOME" AXONFLOW_AUTH='dGVzdA==' /bin/sh -c "cd / && $HH")"
if printf '%s' "$OUT" | jq -e 'has("X-User-Token")|not' >/dev/null 2>&1; then
  echo "PASS: user-token.json with unsafe perms (0644) → refused (no X-User-Token)"
else
  echo "FAIL: loose-perm user-token.json was used: $OUT"; fail=1
fi
rm -rf "$TMPHOME"

# 24) wire-safety: a token candidate carrying a quote / space / CR-LF is
#     DROPPED (header absent), never mangled-and-sent — and the printf-
#     assembled headers JSON stays valid.
for BAD in 'to"ken' 'to ken' "$(printf 'tok\r\nEvil: hdr')"; do
  OUT="$(HOME=/nonexistent-empty-home AXONFLOW_AUTH='dGVzdA==' AXONFLOW_USER_TOKEN="$BAD" run_hh)"
  if printf '%s' "$OUT" | jq -e '(has("X-User-Token")|not)' >/dev/null 2>&1; then
    echo "PASS: wire-unsafe token candidate dropped (valid JSON, no X-User-Token)"
  else
    echo "FAIL: wire-unsafe token candidate not dropped: $(printf '%q' "$OUT")"; fail=1
  fi
done

# ---------------------------------------------------------------------------
# #108 resolver-equivalence legs: a MALFORMED (non-empty, wire-unsafe) env
# token must not suppress the file fallback. resolve_user_token (the hook
# plane) drops the malformed env candidate and falls back to the 0600 file —
# the inline previously read the file only when the env was EMPTY, so the
# same misconfig sent the file token on the hook plane but NO X-User-Token
# on the MCP plane (inconsistent cross-plane scoping). These pin the inline
# to resolve_user_token's semantics on every env×file combo that used to
# drift. Red-on-revert with the pre-#108 inline (`if [ -z "$ut" ]` before
# any strip-check). Resolver-side twins live in tests/test-user-token.sh.
# ---------------------------------------------------------------------------
UT_BAD='bad token with spaces'

# 25) THE #108 fix: malformed env + valid 0600 file → X-User-Token carries
#     the FILE token (same outcome as resolve_user_token on the hook plane).
TMPHOME="$(mktemp -d)"
mkdir -p "$TMPHOME/.config/axonflow"
printf '{"token":"file.tok.value"}' > "$TMPHOME/.config/axonflow/user-token.json"
chmod 600 "$TMPHOME/.config/axonflow/user-token.json"
OUT="$(HOME="$TMPHOME" AXONFLOW_AUTH='dGVzdA==' AXONFLOW_USER_TOKEN="$UT_BAD" /bin/sh -c "cd / && $HH")"
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
   && [ "$(printf '%s' "$OUT" | jq -r '."X-User-Token" // empty')" = "file.tok.value" ]; then
  echo "PASS: malformed env token + valid 0600 file → X-User-Token from file (matches resolve_user_token)"
else
  echo "FAIL: malformed env token suppressed the 0600 file fallback (#108 drift): $OUT"; fail=1
fi

# 26) malformed env + non-0600 file → BOTH candidates refused → header absent.
chmod 644 "$TMPHOME/.config/axonflow/user-token.json"
OUT="$(HOME="$TMPHOME" AXONFLOW_AUTH='dGVzdA==' AXONFLOW_USER_TOKEN="$UT_BAD" /bin/sh -c "cd / && $HH")"
if printf '%s' "$OUT" | jq -e '(has("X-User-Token")|not)' >/dev/null 2>&1; then
  echo "PASS: malformed env token + 0644 file → no X-User-Token (perm gate holds on the fallback)"
else
  echo "FAIL: malformed env + 0644 file emitted a token: $OUT"; fail=1
fi

# 27) malformed env + malformed-content 0600 file → the file value is
#     strip-checked too (never mangled-and-sent) → header absent.
jq -n '{token: "line1\nline2"}' > "$TMPHOME/.config/axonflow/user-token.json"
chmod 600 "$TMPHOME/.config/axonflow/user-token.json"
OUT="$(HOME="$TMPHOME" AXONFLOW_AUTH='dGVzdA==' AXONFLOW_USER_TOKEN="$UT_BAD" /bin/sh -c "cd / && $HH")"
if printf '%s' "$OUT" | jq -e '(has("X-User-Token")|not)' >/dev/null 2>&1; then
  echo "PASS: malformed env token + malformed file token → both dropped, no X-User-Token"
else
  echo "FAIL: malformed env + malformed file emitted a token: $(printf '%q' "$OUT")"; fail=1
fi
rm -rf "$TMPHOME"

# 28) malformed env + NO file → dropped outright, header absent, JSON valid
#     (test 24 covers this shape with other bad candidates; this pins the
#     multi-space candidate used across the #108 matrix).
OUT="$(HOME=/nonexistent-empty-home AXONFLOW_AUTH='dGVzdA==' AXONFLOW_USER_TOKEN="$UT_BAD" run_hh)"
if printf '%s' "$OUT" | jq -e '(has("X-User-Token")|not)' >/dev/null 2>&1; then
  echo "PASS: malformed env token + no file → no X-User-Token (valid JSON)"
else
  echo "FAIL: malformed env + no file emitted a token: $OUT"; fail=1
fi

# 29) precedence unchanged by the #108 restructure: a VALID env token still
#     wins over a valid 0600 file (env validated first, file never read).
TMPHOME="$(mktemp -d)"
mkdir -p "$TMPHOME/.config/axonflow"
printf '{"token":"file.tok.value"}' > "$TMPHOME/.config/axonflow/user-token.json"
chmod 600 "$TMPHOME/.config/axonflow/user-token.json"
OUT="$(HOME="$TMPHOME" AXONFLOW_AUTH='dGVzdA==' AXONFLOW_USER_TOKEN="$UT_GOOD" /bin/sh -c "cd / && $HH")"
if [ "$(printf '%s' "$OUT" | jq -r '."X-User-Token" // empty')" = "$UT_GOOD" ]; then
  echo "PASS: valid env token still wins over the 0600 file after the #108 restructure"
else
  echo "FAIL: env precedence broken by the #108 restructure: $OUT"; fail=1
fi
rm -rf "$TMPHOME"

echo ""
if [ "$fail" -ne 0 ]; then
  echo "FAIL: .mcp.json headersHelper unit test"
  exit 1
fi
echo "PASS: .mcp.json headersHelper unit test"
