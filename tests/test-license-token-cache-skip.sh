#!/usr/bin/env bash
# Regression test: resolve_license_token + license_token_endpoint_compatible
# per ADR-048 + ADR-050.
#
# Two responsibilities, two surfaces:
#  - resolve_license_token: always loads the on-disk cache as a fallback so
#    operators / tests get a deterministic "is there a token at all?" signal.
#  - license_token_endpoint_compatible: returns true unless the cached token's
#    aud claim is community_saas_plugin AND AXONFLOW_ENDPOINT is set to a
#    non-try.getaxonflow.com host. That's the only combination where sending
#    the token to the platform would 401 silently.
#
# Earlier iterations of the fix that didn't survive hostile review:
#  - commit 0f6ade6: skipped cache when AXONFLOW_AUTH was set →
#    community-saas-bootstrap.sh sets AXONFLOW_AUTH on every first-run,
#    so a Pro user on community-saas lost their X-License-Token.
#  - commit 79be132: skipped cache when AXONFLOW_ENDPOINT was a non-
#    try.getaxonflow.com host → broke tests/host-cli-shim's Pro/file
#    scenario (legitimately uses a localhost shim endpoint + file token).
#
# Now: cache loads unconditionally; aud↔endpoint compat is checked
# in license_token_endpoint_compatible and consumed by mcp-auth-headers.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Use a temp HOME so we don't touch the user's real ~/.config/axonflow.
TEST_HOME=$(mktemp -d)
trap "rm -rf $TEST_HOME" EXIT
export HOME="$TEST_HOME"
export XDG_CONFIG_HOME="$TEST_HOME/.config"
mkdir -p "$XDG_CONFIG_HOME/axonflow"

# A valid-looking AXON- token (signature shape).
CACHED_TOKEN="AXON-eyJ0aWVyIjoiUHJvIiwib3JnX2lkIjoiY29tbXVuaXR5LXNhYXMiLCJpc3N1ZWRfYXQiOiIyMDI2MDUwNCIsImV4cGlyZXNfYXQiOiIyMTI2MDUwNCIsImF1ZCI6ImNvbW11bml0eV9zYWFzX3BsdWdpbiJ9.AAAA"
ENV_TOKEN="AXON-ZW52LXRva2VuLXNlbnRpbmVs.AAAA"

cat > "$XDG_CONFIG_HOME/axonflow/license-token.json" <<JSON
{"token":"$CACHED_TOKEN","saved_at":"2026-05-04T12:03:58Z"}
JSON
chmod 600 "$XDG_CONFIG_HOME/axonflow/license-token.json"

PASS=0; FAIL=0
assert() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS $name"; PASS=$((PASS+1))
  else
    echo "  FAIL $name: expected=$expected actual=$actual"; FAIL=$((FAIL+1))
  fi
}

# The script depends on a single LICENSE_TOKEN_FILE — override via HOME override
# is sufficient if license-token.sh resolves via $HOME. Source it and override the
# computed file path to point at our test fixture.
source_under_test() {
  unset AXONFLOW_LICENSE_TOKEN AXONFLOW_ENDPOINT AXONFLOW_AUTH AXONFLOW_CONFIG_DIR
  # Provide caller-set vars
  for kv in "$@"; do
    eval "export $kv"
  done
  (
    LICENSE_TOKEN_CONFIG_DIR="$XDG_CONFIG_HOME/axonflow"
    LICENSE_TOKEN_FILE="$LICENSE_TOKEN_CONFIG_DIR/license-token.json"
    # shellcheck source=../scripts/license-token.sh
    source "$PLUGIN_ROOT/scripts/license-token.sh"
    resolve_license_token
    echo "${AXONFLOW_LICENSE_TOKEN:-}"
  )
}

# A second source_under_test that returns the compat verdict instead of the
# token value, so we can assert both surfaces.
compat_under_test() {
  unset AXONFLOW_LICENSE_TOKEN AXONFLOW_ENDPOINT AXONFLOW_AUTH AXONFLOW_CONFIG_DIR
  for kv in "$@"; do
    eval "export $kv"
  done
  (
    LICENSE_TOKEN_CONFIG_DIR="$XDG_CONFIG_HOME/axonflow"
    LICENSE_TOKEN_FILE="$LICENSE_TOKEN_CONFIG_DIR/license-token.json"
    source "$PLUGIN_ROOT/scripts/license-token.sh"
    resolve_license_token
    if license_token_endpoint_compatible; then echo "compat"; else echo "incompat"; fi
  )
}

echo "--- resolve_license_token: cache always loads (signal layer) ---"

# A — community-saas (no endpoint): cache loads.
RESULT=$(source_under_test)
assert "A community-saas (no endpoint) loads cache" "$RESULT" "$CACHED_TOKEN"

# B — community-saas with SaaS endpoint: cache loads.
RESULT=$(source_under_test AXONFLOW_ENDPOINT="https://try.getaxonflow.com")
assert "B community-saas (try.getaxonflow.com endpoint) loads cache" "$RESULT" "$CACHED_TOKEN"

# C — self-hosted endpoint: cache STILL loads (we deal with it at compat layer).
RESULT=$(source_under_test AXONFLOW_ENDPOINT="http://localhost:8080")
assert "C self-hosted (localhost:8080) loads cache (compat layer handles drop)" "$RESULT" "$CACHED_TOKEN"

# C2 — community-saas with AXONFLOW_AUTH set: cache loads (regression case).
RESULT=$(source_under_test AXONFLOW_AUTH="Basic Y3NfdGVzdDpkdW1teQ==")
assert "C2 community-saas with AUTH set loads cache" "$RESULT" "$CACHED_TOKEN"

# D — env var wins regardless.
RESULT=$(source_under_test AXONFLOW_LICENSE_TOKEN="$ENV_TOKEN" AXONFLOW_ENDPOINT="http://localhost:8080")
assert "D env-set token wins on self-hosted endpoint" "$RESULT" "$ENV_TOKEN"

echo
echo "--- license_token_endpoint_compatible: per-request drop layer ---"

# E — community-saas-aud cached token + community-saas endpoint: compat.
RESULT=$(compat_under_test AXONFLOW_ENDPOINT="https://try.getaxonflow.com")
assert "E community-saas-aud token + try.getaxonflow.com" "$RESULT" "compat"

# F — community-saas-aud cached token + self-hosted endpoint: INCOMPAT (the actual leak protection).
RESULT=$(compat_under_test AXONFLOW_ENDPOINT="http://localhost:8080")
assert "F community-saas-aud token + self-hosted endpoint = incompat" "$RESULT" "incompat"

# G — no endpoint set: defaults to compat (community-saas is the default deployment).
RESULT=$(compat_under_test)
assert "G no endpoint defaults to compat" "$RESULT" "compat"

# H — env-set token with self_hosted aud should be compatible on self-hosted endpoint.
# Build a minimal AXON- token with aud=axonflow.self_hosted.full
SELF_HOSTED_PAYLOAD='{"tier":"Enterprise","aud":"axonflow.self_hosted.full","issued_at":"20260101","expires_at":"21260101"}'
SELF_HOSTED_B64=$(echo -n "$SELF_HOSTED_PAYLOAD" | python3 -c "import sys,base64;sys.stdout.write(base64.urlsafe_b64encode(sys.stdin.read().encode()).decode().rstrip('='))")
SELF_HOSTED_TOKEN="AXON-${SELF_HOSTED_B64}.AAAA"
RESULT=$(compat_under_test AXONFLOW_LICENSE_TOKEN="$SELF_HOSTED_TOKEN" AXONFLOW_ENDPOINT="http://localhost:8080")
assert "H self-hosted-aud token + self-hosted endpoint = compat" "$RESULT" "compat"

# I) AXONFLOW_CONFIG_DIR parity: the resolver reads license-token.json from
#    the relocated config dir — matching the inline .mcp.json headersHelper,
#    self-hosted-auth.sh, status.sh, and user-token.sh — so a relocated
#    fleet gets X-License-Token on the hook plane too (and login.sh, which
#    derives LICENSE_TOKEN_FILE from this script, persists where the
#    readers look).
CFGDIR=$(mktemp -d)
printf '{"token":"AXON-cfgdir-parity-token-00000000000000000000"}' > "$CFGDIR/license-token.json"
chmod 600 "$CFGDIR/license-token.json"
RESULT=$( (
  unset AXONFLOW_LICENSE_TOKEN AXONFLOW_ENDPOINT AXONFLOW_AUTH
  export AXONFLOW_CONFIG_DIR="$CFGDIR" HOME=/nonexistent-empty-home
  # shellcheck source=../scripts/license-token.sh
  source "$PLUGIN_ROOT/scripts/license-token.sh"
  resolve_license_token
  echo "${AXONFLOW_LICENSE_TOKEN:-}"
) )
assert "I AXONFLOW_CONFIG_DIR relocated license-token.json resolves" "$RESULT" "AXON-cfgdir-parity-token-00000000000000000000"
rm -rf "$CFGDIR"

echo
echo "=== license-token cache-skip + endpoint-compat regression: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
