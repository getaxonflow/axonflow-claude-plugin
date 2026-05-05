#!/usr/bin/env bash
# Claude Code runtime E2E: V1 SaaS Plugin Pro tier-line expiry surface.
#
# Drives the user-facing slash-command surface (`/axonflow-status`, which
# is just `bash $CLAUDE_PLUGIN_ROOT/scripts/status.sh`) against three
# realistic license-token states and asserts the actual stdout matches
# the documented tier-line shapes:
#
#   - Free       → "tier=Free (no Pro license configured)"
#   - Pro active → "tier=Pro (expires YYYY-MM-DD, N days remaining)"
#   - Pro expired → "tier=Free (Pro expired YYYY-MM-DD — visit ... to renew)"
#
# Why this is real-surface runtime proof (HARD RULE #0):
#   - The script under test IS the script the user invokes from
#     /axonflow-status — same file, same path, same env-var resolution.
#   - The license token IS a real AXON-prefixed JWT (header.payload.sig
#     base64url-encoded per RFC 7519); the JWT-parsing branch in
#     status.sh does NOT distinguish a platform-minted token from a
#     test-minted one structurally — both decode the same way and exit
#     the same code path. The platform's signature validation is a
#     separate concern that lives in PluginClaimMiddleware on the agent
#     and is exercised by runtime-e2e/license-token/test.sh.
#   - There is no network mock, no fake stdout capture, no shimmed
#     command. We invoke the actual `scripts/status.sh` against an
#     isolated $HOME and assert the actual stdout grep-shape.
#
# This test is the runtime proof for the JWT-exp-extraction code path.
# The wire-up that actually forwards X-License-Token on a governed call
# is covered by runtime-e2e/license-token/test.sh — separate concern.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATUS_SH="${PLUGIN_DIR}/scripts/status.sh"

if [ ! -f "$STATUS_SH" ]; then
  echo "FAIL: required file missing: $STATUS_SH"
  exit 1
fi

if ! command -v base64 >/dev/null 2>&1; then
  echo "SKIP: base64 not on PATH"
  exit 0
fi
if ! command -v date >/dev/null 2>&1; then
  echo "SKIP: date not on PATH"
  exit 0
fi

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

# Mint a structurally-valid AXON- token whose JWT payload contains a given
# `exp` (unix epoch seconds). Signature segment is a fixed placeholder
# string padded to a realistic length; status.sh extracts `exp` only,
# does NOT validate the signature (that's the platform's job).
mint_axon_jwt() {
  local exp_epoch="$1"
  local hdr
  hdr=$(printf '%s' '{"alg":"EdDSA","typ":"JWT"}' | base64 | tr '+/' '-_' | tr -d '=')
  local payload
  payload=$(printf '{"sub":"runtime-e2e","exp":%s}' "$exp_epoch" | base64 | tr '+/' '-_' | tr -d '=')
  # Pad the signature out so the whole token is comfortably long; the
  # license-token.sh resolver requires AXON- prefix + length >= 32.
  local sig="placeholder-signature-padding-padding-padding-padding-padding-pa"
  printf 'AXON-%s.%s.%s' "$hdr" "$payload" "$sig"
}

TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT

echo "=== runtime-e2e: V1 SaaS Plugin Pro tier-expiry surface ==="
echo "Plugin dir: $PLUGIN_DIR"
echo "Script:     $STATUS_SH"
echo ""

# -----------------------------------------------------------------------------
# Test 1: Free tier (no token, no env, no on-disk file).
# -----------------------------------------------------------------------------
echo "Test 1: Free tier — no Pro license configured"
FREE_OUT=$(AXONFLOW_LICENSE_TOKEN='' \
  HOME="$TMP_HOME" \
  AXONFLOW_CONFIG_DIR="$TMP_HOME/empty" \
  bash "$STATUS_SH" 2>&1 || true)
if echo "$FREE_OUT" | grep -q "tier=Free (no Pro license configured)"; then
  pass "Free tier-line shape (no Pro license configured)"
else
  fail "Free tier-line missing expected shape; got:"
  echo "$FREE_OUT" | sed 's/^/      /'
fi

# -----------------------------------------------------------------------------
# Test 2: Pro tier active (token with exp ~30 days in the future).
# -----------------------------------------------------------------------------
echo ""
echo "Test 2: Pro tier active — exp in the future"
PRO_EXP=$(( $(date -u +%s) + 30 * 86400 ))
PRO_TOKEN=$(mint_axon_jwt "$PRO_EXP")
PRO_OUT=$(AXONFLOW_LICENSE_TOKEN="$PRO_TOKEN" \
  HOME="$TMP_HOME" \
  AXONFLOW_CONFIG_DIR="$TMP_HOME/empty" \
  bash "$STATUS_SH" 2>&1 || true)
if echo "$PRO_OUT" | grep -qE "tier=Pro \(expires [0-9]{4}-[0-9]{2}-[0-9]{2}, [0-9]+ days remaining\)"; then
  pass "Pro-active tier-line shape (expires YYYY-MM-DD, N days remaining)"
else
  fail "Pro-active tier-line missing expected shape; got:"
  echo "$PRO_OUT" | sed 's/^/      /'
fi
# Token-leak guard: full token must NEVER appear in stdout.
if echo "$PRO_OUT" | grep -qF "$PRO_TOKEN"; then
  fail "Pro-active output leaked full token"
else
  pass "Pro-active output redacts full token"
fi
# Last-4 redaction: the AXON-...XXXX preview shows up.
PRO_TAIL4="${PRO_TOKEN: -4}"
if echo "$PRO_OUT" | grep -qF "AXON-...${PRO_TAIL4}"; then
  pass "Pro-active output shows last-4 redacted preview (AXON-...${PRO_TAIL4})"
else
  fail "Pro-active output missing last-4 preview"
fi

# -----------------------------------------------------------------------------
# Test 3: Pro tier expired (token with exp ~365 days in the past).
# -----------------------------------------------------------------------------
echo ""
echo "Test 3: Pro tier expired — exp in the past"
EXPIRED_EXP=$(( $(date -u +%s) - 365 * 86400 ))
EXPIRED_TOKEN=$(mint_axon_jwt "$EXPIRED_EXP")
EXPIRED_OUT=$(AXONFLOW_LICENSE_TOKEN="$EXPIRED_TOKEN" \
  HOME="$TMP_HOME" \
  AXONFLOW_CONFIG_DIR="$TMP_HOME/empty" \
  bash "$STATUS_SH" 2>&1 || true)
if echo "$EXPIRED_OUT" | grep -qE "tier=Free \(Pro expired [0-9]{4}-[0-9]{2}-[0-9]{2} — visit https?://[^ ]+ to renew\)"; then
  pass "Pro-expired tier-line shape (Pro expired YYYY-MM-DD — visit ... to renew)"
else
  fail "Pro-expired tier-line missing expected shape; got:"
  echo "$EXPIRED_OUT" | sed 's/^/      /'
fi
if echo "$EXPIRED_OUT" | grep -qF "$EXPIRED_TOKEN"; then
  fail "Pro-expired output leaked full token"
else
  pass "Pro-expired output redacts full token"
fi
# The renew CTA inline help block must appear so users know what to do next.
if echo "$EXPIRED_OUT" | grep -q "After renewal, run /axonflow-login --token"; then
  pass "Pro-expired output surfaces the /axonflow-login renewal hint"
else
  fail "Pro-expired output missing /axonflow-login renewal hint"
fi

echo ""
echo "Summary: $PASS PASS, $FAIL FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "PASS: V1 SaaS Plugin Pro tier-expiry surface verified end-to-end"
exit 0
