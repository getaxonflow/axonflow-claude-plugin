#!/usr/bin/env bash
# Content assertion for skills/axonflow-status/SKILL.md.
#
# Locks in the rule that the "What to do" section preferences the LOCAL
# script path over the MCP tool path for tenant_id / tier queries —
# saves an agent round-trip on the most common operator question. Wired
# into the CI workflow so a future SKILL edit can't silently re-introduce
# the round-trip-first preference.
#
# Three independent assertions, each cheap. The test runs in the
# always-on tests/ tree (NOT runtime-e2e/, since this is a content
# check on a static markdown asset, not a runtime proof).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="${PLUGIN_DIR}/skills/axonflow-status/SKILL.md"

if [ ! -f "$SKILL_FILE" ]; then
  echo "FAIL: $SKILL_FILE missing"
  exit 1
fi

PASS=0
FAIL=0

# Assertion 1: the FIRST numbered step ("1.") in the "What to do" section
# must reference the local script — not the MCP tool. Extract the body
# between "## What to do" and the next "##" heading, then read the first
# numbered item.
WHATTODO=$(awk '
  /^## What to do/ {capture=1; next}
  /^## / && capture {exit}
  capture {print}
' "$SKILL_FILE")

if [ -z "$WHATTODO" ]; then
  echo "FAIL: could not extract '## What to do' section from $SKILL_FILE"
  exit 1
fi

FIRST_STEP=$(echo "$WHATTODO" | awk '/^1\./ {capture=1; print; next} /^2\./ {exit} capture {print}')

if echo "$FIRST_STEP" | grep -qF "scripts/status.sh"; then
  echo "  PASS: step 1 references the local scripts/status.sh path"
  PASS=$((PASS+1))
else
  echo "  FAIL: step 1 does NOT reference the local scripts/status.sh path"
  echo "    --- step 1 body ---"
  echo "$FIRST_STEP" | sed 's/^/    /'
  echo "    --- end ---"
  FAIL=$((FAIL+1))
fi

if echo "$FIRST_STEP" | grep -qiE 'axonflow_get_tenant_id|MCP tool'; then
  echo "  FAIL: step 1 mentions the MCP tool — must defer that to a fallback step"
  FAIL=$((FAIL+1))
else
  echo "  PASS: step 1 does not mention the MCP tool"
  PASS=$((PASS+1))
fi

# Assertion 2: the rationale text must call out "no agent round-trip" or
# equivalent — locks in the WHY so a future editor can't drop the local
# preference without explicitly thinking about the round-trip cost.
if echo "$FIRST_STEP" | grep -qiE 'no agent round-trip|without an agent round-trip|no HTTP call'; then
  echo "  PASS: step 1 calls out the no-round-trip benefit"
  PASS=$((PASS+1))
else
  echo "  FAIL: step 1 missing 'no agent round-trip' / 'no HTTP call' rationale"
  FAIL=$((FAIL+1))
fi

# Assertion 3: the MCP tool path must still be DOCUMENTED somewhere later
# in the skill — we're flipping the preference, not deleting the
# fallback. (Without this, a future editor might drop the MCP reference
# entirely and lose the server-truth escape hatch.)
if echo "$WHATTODO" | grep -qF "axonflow_get_tenant_id"; then
  echo "  PASS: MCP tool axonflow_get_tenant_id still documented as fallback"
  PASS=$((PASS+1))
else
  echo "  FAIL: MCP tool axonflow_get_tenant_id reference removed entirely (must keep as fallback)"
  FAIL=$((FAIL+1))
fi

echo
echo "==============================="
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
