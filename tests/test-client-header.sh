#!/usr/bin/env bash
# Unit test for scripts/client-header.sh — ADR-050 §4.
#
# Asserts the helper sets AXONFLOW_CLIENT_HEADER to "claude-code-plugin/<version>"
# where <version> matches .claude-plugin/plugin.json's `version` field, and that
# subsequent sourcing is idempotent.
#
# Stdlib-only (bash + jq). No live AxonFlow stack required.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${PLUGIN_DIR}/scripts/client-header.sh"
PLUGIN_JSON="${PLUGIN_DIR}/.claude-plugin/plugin.json"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi

# Test 1: helper resolves the version from plugin.json
EXPECTED_VERSION=$(jq -r '.version' "$PLUGIN_JSON")
EXPECTED_HEADER="claude-code-plugin/${EXPECTED_VERSION}"

# Source in a clean subshell so we don't pollute the parent env.
ACTUAL=$(unset AXONFLOW_CLIENT_HEADER; . "$SCRIPT_PATH"; echo "$AXONFLOW_CLIENT_HEADER")
if [ "$ACTUAL" = "$EXPECTED_HEADER" ]; then
  pass "client-header.sh sets AXONFLOW_CLIENT_HEADER=$EXPECTED_HEADER"
else
  fail "expected '$EXPECTED_HEADER', got '$ACTUAL'"
fi

# Test 2: header format is <client-id>/<semver> — agent-side parsing depends
# on this exact shape (split on '/', map prefix to scope).
if [[ "$ACTUAL" =~ ^claude-code-plugin/[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  pass "header format matches <client-id>/<semver>"
else
  fail "header '$ACTUAL' does not match <client-id>/<semver>"
fi

# Test 3: idempotent — sourcing a second time does not change the value or
# error out under set -u.
ACTUAL2=$(unset AXONFLOW_CLIENT_HEADER
          . "$SCRIPT_PATH"
          . "$SCRIPT_PATH"  # second source — must not blow up
          echo "$AXONFLOW_CLIENT_HEADER")
if [ "$ACTUAL2" = "$EXPECTED_HEADER" ]; then
  pass "double-source is idempotent"
else
  fail "double-source changed value to '$ACTUAL2'"
fi

# Test 4: idempotent under -u (set -u must not trip on internal vars after unset)
if (set -u; unset AXONFLOW_CLIENT_HEADER; . "$SCRIPT_PATH"; echo "$AXONFLOW_CLIENT_HEADER" >/dev/null) 2>/dev/null; then
  pass "client-header.sh works under set -u"
else
  fail "client-header.sh trips set -u"
fi

echo ""
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
