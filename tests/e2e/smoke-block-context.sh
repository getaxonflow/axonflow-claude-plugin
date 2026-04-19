#!/usr/bin/env bash
# Plugin smoke E2E: install-and-use sanity check against a live AxonFlow
# stack. Feeds a SQLi-bearing Bash tool invocation into pre-tool-check.sh
# and asserts the hook returns the Claude Code `permissionDecision: deny`
# shape with Plugin Batch 1 richer-context markers (decision_id, risk) in
# the reason text.
#
# Scope: smoke-only — install wiring + one local deny UX. The full
# install-and-use matrix (explain, override lifecycle, audit filter
# parity, cache invalidation) lives alongside the platform in
# axonflow-enterprise/tests/e2e/plugin-batch-1/claude-install/.
#
# Usage:
#   AXONFLOW_ENDPOINT=http://localhost:8080 \
#   AXONFLOW_CLIENT_ID=demo-client \
#   AXONFLOW_CLIENT_SECRET=demo-secret \
#     bash tests/e2e/smoke-block-context.sh
#
# CI trigger: workflow_dispatch only (GitHub-hosted runners have no
# local stack; PR gating needs a self-hosted runner).
# -uo pipefail (no -e) so the errors=$((errors+1)) accumulator + FAIL
# diagnostics always print even if a jq filter exits non-zero mid-script.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_SCRIPT="$REPO_ROOT/scripts/pre-tool-check.sh"

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"
: "${AXONFLOW_CLIENT_ID:=demo-client}"
: "${AXONFLOW_CLIENT_SECRET:=demo-secret}"

export AXONFLOW_ENDPOINT
export AXONFLOW_AUTH="$(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)"

# Fail fast with a useful message when the stack isn't reachable, rather
# than dumping a 0-length hook output and confusing the diff.
if ! curl -sSf -o /dev/null --max-time 5 "$AXONFLOW_ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $AXONFLOW_ENDPOINT/health"
  echo "      Start one via axonflow-enterprise scripts/setup-e2e-testing.sh"
  exit 0
fi

INPUT='{"tool_name":"Bash","tool_input":{"command":"psql -c \"SELECT * FROM users WHERE id='"'"'1'"'"' OR 1=1--\""}}'

OUTPUT=$(echo "$INPUT" | bash "$HOOK_SCRIPT" 2>&1)
echo "--- hook output ---"
echo "$OUTPUT"
echo "---"

errors=0
if [ -z "$OUTPUT" ]; then
  echo "FAIL: hook produced no output (expected deny)"
  errors=$((errors + 1))
fi
if ! echo "$OUTPUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  echo "FAIL: expected .hookSpecificOutput.permissionDecision == \"deny\""
  errors=$((errors + 1))
fi

REASON=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)
echo "permission decision reason: $REASON"

if ! echo "$REASON" | grep -qE "decision:"; then
  echo "FAIL: reason missing 'decision:' marker (Plugin Batch 1 richer context)"
  errors=$((errors + 1))
fi
if ! echo "$REASON" | grep -qE "risk:"; then
  echo "FAIL: reason missing 'risk:' marker (Plugin Batch 1 richer context)"
  errors=$((errors + 1))
fi

if [ $errors -gt 0 ]; then
  echo "FAIL: smoke scenario failed with $errors error(s)"
  exit 1
fi
echo "PASS: smoke — Claude Code hook denies SQLi Bash with richer context"
