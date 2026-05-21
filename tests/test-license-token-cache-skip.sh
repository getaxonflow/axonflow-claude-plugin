#!/usr/bin/env bash
# Regression test: resolve_license_token cache-skip logic per ADR-048.
#
# Covers four cases:
#  A) Community-saas mode (AXONFLOW_ENDPOINT unset)        → cache LOADED
#  B) Community-saas mode (AXONFLOW_ENDPOINT=try.getaxonflow.com) → cache LOADED
#  C) Self-hosted with localhost endpoint                  → cache SKIPPED
#  D) AXONFLOW_LICENSE_TOKEN env wins regardless of mode   → env wins
#
# The bug: prior fix (commit 0f6ade6) used AXONFLOW_AUTH presence as
# the discriminator, but community-saas-bootstrap.sh sets AXONFLOW_AUTH
# on every first-run, so community-saas Pro users would have lost
# their X-License-Token. This test asserts the corrected discriminator.

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
  unset AXONFLOW_LICENSE_TOKEN AXONFLOW_ENDPOINT AXONFLOW_AUTH
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

# Case A — community-saas (no endpoint, no auth): cache loads.
RESULT=$(source_under_test)
assert "A community-saas (no endpoint)" "$RESULT" "$CACHED_TOKEN"

# Case B — community-saas with explicit SaaS endpoint: cache loads.
RESULT=$(source_under_test AXONFLOW_ENDPOINT="https://try.getaxonflow.com")
assert "B community-saas (try.getaxonflow.com endpoint)" "$RESULT" "$CACHED_TOKEN"

# Case C — self-hosted endpoint: cache is SKIPPED.
RESULT=$(source_under_test AXONFLOW_ENDPOINT="http://localhost:8080")
assert "C self-hosted (localhost:8080)" "$RESULT" ""

# Case C2 — even with AXONFLOW_AUTH set (community-saas bootstrap shape),
# cache should LOAD as long as endpoint is community-saas (or empty).
# This is the regression the hostile-review fix narrowed.
RESULT=$(source_under_test AXONFLOW_AUTH="Basic Y3NfdGVzdDpkdW1teQ==")
assert "C2 community-saas with AUTH set (the regression case)" "$RESULT" "$CACHED_TOKEN"

# Case D — env var wins regardless of mode.
RESULT=$(source_under_test AXONFLOW_LICENSE_TOKEN="$ENV_TOKEN" AXONFLOW_ENDPOINT="http://localhost:8080")
assert "D env-set token wins on self-hosted endpoint" "$RESULT" "$ENV_TOKEN"

echo
echo "=== license-token cache-skip regression: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
