#!/usr/bin/env bash
# Unit tests for scripts/user-token.sh (the per-user authorization token
# resolver, axonflow-enterprise#2935) and its consumption by the
# mcp-auth-headers.sh reference impl.
#
# Pins the canonical resolution order (env AXONFLOW_USER_TOKEN wins →
# 0600-guarded ~/.config/axonflow/user-token.json), the 0600 rejection, the
# wire-safety guard (whitespace/control/quote/backslash candidates are DROPPED
# — the platform fails closed on a presented-but-invalid token, so a mangled
# credential must never reach the wire), and that diagnostics never leak the
# token value. The .mcp.json inline port of the same contract is pinned by
# tests/test-mcp-headers.sh; the hook wire behavior by
# tests/test-user-token-header-wire.sh.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi

GOOD_TOKEN='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJlbWFpbCI6ImRldkBleGFtcGxlLmNvbSJ9.abc123-_sig'

# resolve <home> <env-token> — source the helper in a clean subshell and print
# the resolved AXONFLOW_USER_TOKEN (stdout) so assertions stay hermetic.
# Stderr passes through to the caller's capture.
resolve() {
  local home="$1" envtok="$2" cfgdir="${3:-}"
  (
    export HOME="$home"
    # Hermetic: a host AXONFLOW_CONFIG_DIR must not bleed into legs that
    # exercise the $HOME default; leg 6c passes it explicitly.
    if [ -n "$cfgdir" ]; then export AXONFLOW_CONFIG_DIR="$cfgdir"; else unset AXONFLOW_CONFIG_DIR; fi
    if [ -n "$envtok" ]; then export AXONFLOW_USER_TOKEN="$envtok"; else unset AXONFLOW_USER_TOKEN; fi
    # shellcheck disable=SC1091
    . "$ROOT/scripts/user-token.sh"
    resolve_user_token
    printf '%s' "${AXONFLOW_USER_TOKEN:-}"
  )
}

echo "== user-token.sh resolver unit tests =="

# 1) Nothing configured → empty (the common fleet state).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$(resolve "$WORK/no-home" "" 2>/dev/null)"
[ -z "$OUT" ] && pass "unconfigured → no token resolved" \
  || fail "unconfigured resolved to something: $OUT"

# 2) Env var wins outright (even when a file exists with a different token).
mkdir -p "$WORK/home1/.config/axonflow"
printf '{"token":"file.tok.value"}' > "$WORK/home1/.config/axonflow/user-token.json"
chmod 600 "$WORK/home1/.config/axonflow/user-token.json"
OUT="$(resolve "$WORK/home1" "$GOOD_TOKEN" 2>/dev/null)"
[ "$OUT" = "$GOOD_TOKEN" ] && pass "env token wins over file" \
  || fail "env precedence broken: $OUT"

# 3) File fallback loads a 0600 file.
OUT="$(resolve "$WORK/home1" "" 2>/dev/null)"
[ "$OUT" = "file.tok.value" ] && pass "0600 file token loads when env unset" \
  || fail "0600 file load broken: $OUT"

# 4) Non-0600 file is REJECTED with a stderr warning that names the file.
chmod 644 "$WORK/home1/.config/axonflow/user-token.json"
ERR="$(resolve "$WORK/home1" "" 2>&1 >/dev/null)"
OUT="$(resolve "$WORK/home1" "" 2>/dev/null)"
if [ -z "$OUT" ]; then
  pass "0644 file rejected (no token resolved)"
else
  fail "0644 file was loaded: $OUT"
fi
printf '%s' "$ERR" | grep -q "unsafe permissions" \
  && pass "0644 rejection warns on stderr" \
  || fail "no unsafe-permissions warning on stderr: $ERR"
chmod 600 "$WORK/home1/.config/axonflow/user-token.json"

# 5) Wire-safety guard: env token with embedded space / quote / backslash /
#    newline is dropped, and the diagnostic NEVER contains the value.
for bad in 'tok with space' 'tok"quote' 'tok\backslash' "$(printf 'tok\nnewline')"; do
  ERR="$(resolve "$WORK/no-home" "$bad" 2>&1 >/dev/null)"
  OUT="$(resolve "$WORK/no-home" "$bad" 2>/dev/null)"
  if [ -n "$OUT" ]; then
    fail "malformed env token was resolved: $OUT"
    continue
  fi
  if printf '%s' "$ERR" | grep -qF "tok"; then
    fail "diagnostic leaked the token value: $ERR"
  else
    pass "malformed env token dropped without leaking its value"
  fi
done

# 6) Same guard on the FILE path (a mis-pasted multi-line token in the json).
mkdir -p "$WORK/home2/.config/axonflow"
jq -n '{token: "line1\nline2"}' > "$WORK/home2/.config/axonflow/user-token.json"
chmod 600 "$WORK/home2/.config/axonflow/user-token.json"
ERR="$(resolve "$WORK/home2" "" 2>&1 >/dev/null)"
OUT="$(resolve "$WORK/home2" "" 2>/dev/null)"
if [ -z "$OUT" ]; then
  pass "malformed file token dropped"
else
  fail "malformed file token was resolved: $OUT"
fi
printf '%s' "$ERR" | grep -qF "line1" \
  && fail "file diagnostic leaked the token value" \
  || pass "file diagnostic does not leak the token value"

# 6b) #108 equivalence matrix (resolver side): a MALFORMED env token is
#     dropped and the resolver falls back to the file — the file still gets
#     the full treatment (0600 gate + wire-safety). These are the combos the
#     .mcp.json inline used to drift on (tests/test-mcp-headers.sh pins the
#     inline's side of the same matrix).
#     malformed env + valid 0600 file → the FILE token resolves.
OUT="$(resolve "$WORK/home1" 'bad token with spaces' 2>/dev/null)"
[ "$OUT" = "file.tok.value" ] && pass "malformed env token falls back to the 0600 file token" \
  || fail "malformed env + valid file did not resolve the file token: $OUT"
#     malformed env + non-0600 file → nothing resolves.
chmod 644 "$WORK/home1/.config/axonflow/user-token.json"
OUT="$(resolve "$WORK/home1" 'bad token with spaces' 2>/dev/null)"
[ -z "$OUT" ] && pass "malformed env + 0644 file → no token (perm gate holds on the fallback)" \
  || fail "malformed env + 0644 file resolved: $OUT"
chmod 600 "$WORK/home1/.config/axonflow/user-token.json"
#     malformed env + malformed-content 0600 file → nothing resolves.
OUT="$(resolve "$WORK/home2" 'bad token with spaces' 2>/dev/null)"
[ -z "$OUT" ] && pass "malformed env + malformed file token → both dropped" \
  || fail "malformed env + malformed file resolved: $OUT"

# 6c) AXONFLOW_CONFIG_DIR parity (#109 R3 follow-up): the relocated config
#     dir is a supported override honored by the .mcp.json inline
#     headersHelper (`cfg=`), self-hosted-auth.sh, and status.sh — the
#     resolver must read the token file from it too, with the SAME 0600
#     discipline, or a relocated fleet gets the token on the MCP plane but
#     not the hooks (the #108 drift class on the dir axis). Inline twin:
#     tests/test-mcp-headers.sh leg 30.
CFGDIR="$WORK/cfgdir-6c"
mkdir -p "$CFGDIR"
printf '{"token":"cfgdir.tok.value"}' > "$CFGDIR/user-token.json"
chmod 600 "$CFGDIR/user-token.json"
OUT="$(resolve "$WORK/no-home" '' "$CFGDIR" 2>/dev/null)"
[ "$OUT" = "cfgdir.tok.value" ] && pass "AXONFLOW_CONFIG_DIR override: 0600 token file resolves from the relocated dir" \
  || fail "AXONFLOW_CONFIG_DIR token file did not resolve: '$OUT'"
chmod 644 "$CFGDIR/user-token.json"
OUT="$(resolve "$WORK/no-home" '' "$CFGDIR" 2>/dev/null)"
[ -z "$OUT" ] && pass "AXONFLOW_CONFIG_DIR override: 0644 token file still refused (perm gate follows the dir)" \
  || fail "AXONFLOW_CONFIG_DIR 0644 file resolved: '$OUT'"

# 7) A trailing-newline-only artifact never happens via jq -r (it strips it),
#    but an env var exported with a literal trailing space must be dropped,
#    not silently "fixed" — a stripped token would fail HS256 verification
#    server-side anyway and turn every call into a fail-closed denial.
OUT="$(resolve "$WORK/no-home" "${GOOD_TOKEN} " 2>/dev/null)"
[ -z "$OUT" ] && pass "trailing-space env token dropped (never mangled-and-sent)" \
  || fail "trailing-space env token resolved: $OUT"

echo ""
echo "== mcp-auth-headers.sh reference impl =="

# 8) Configured → X-User-Token present in the emitted JSON.
OUT="$(HOME="$WORK/no-home" AXONFLOW_AUTH='dGVzdA==' AXONFLOW_ENDPOINT='http://selfhosted.local' \
  AXONFLOW_USER_TOKEN="$GOOD_TOKEN" AXONFLOW_USER_EMAIL='dev@example.com' \
  bash "$ROOT/scripts/mcp-auth-headers.sh" 2>/dev/null)"
[ "$(printf '%s' "$OUT" | jq -r '."X-User-Token" // empty')" = "$GOOD_TOKEN" ] \
  && pass "reference impl emits X-User-Token when configured" \
  || fail "reference impl missing X-User-Token: $OUT"

# 9) Unconfigured → the emitted JSON has NO X-User-Token key AND is otherwise
#    identical to the configured run minus that key (proves strictly-additive).
BASE="$(HOME="$WORK/no-home" AXONFLOW_AUTH='dGVzdA==' AXONFLOW_ENDPOINT='http://selfhosted.local' \
  AXONFLOW_USER_EMAIL='dev@example.com' \
  bash "$ROOT/scripts/mcp-auth-headers.sh" 2>/dev/null)"
if [ "$(printf '%s' "$BASE" | jq 'has("X-User-Token")')" = "false" ]; then
  pass "reference impl omits X-User-Token when unconfigured"
else
  fail "unconfigured run emitted X-User-Token: $BASE"
fi
STRIPPED="$(printf '%s' "$OUT" | jq -Sc 'del(."X-User-Token")')"
[ "$STRIPPED" = "$(printf '%s' "$BASE" | jq -Sc .)" ] \
  && pass "configured output == unconfigured output + X-User-Token (no other drift)" \
  || fail "header drift beyond X-User-Token: configured=$STRIPPED unconfigured=$BASE"

# 10) File-token via the reference impl (0600) → present; 0644 → absent.
OUT="$(HOME="$WORK/home1" AXONFLOW_AUTH='dGVzdA==' AXONFLOW_ENDPOINT='http://selfhosted.local' \
  bash "$ROOT/scripts/mcp-auth-headers.sh" 2>/dev/null)"
[ "$(printf '%s' "$OUT" | jq -r '."X-User-Token" // empty')" = "file.tok.value" ] \
  && pass "reference impl loads the 0600 file token" \
  || fail "reference impl file token broken: $OUT"
chmod 644 "$WORK/home1/.config/axonflow/user-token.json"
OUT="$(HOME="$WORK/home1" AXONFLOW_AUTH='dGVzdA==' AXONFLOW_ENDPOINT='http://selfhosted.local' \
  bash "$ROOT/scripts/mcp-auth-headers.sh" 2>/dev/null)"
[ "$(printf '%s' "$OUT" | jq 'has("X-User-Token")')" = "false" ] \
  && pass "reference impl rejects the 0644 file token" \
  || fail "reference impl loaded a 0644 file token: $OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
