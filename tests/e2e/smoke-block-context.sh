#!/usr/bin/env bash
# Plugin smoke E2E: install-and-use sanity check against a live AxonFlow
# stack. Feeds a destructive Bash tool invocation, in the hook JSON Claude
# Code sends (tests/fixtures/claude-code-hook-json/bash-pre.json), into
# pre-tool-check.sh and asserts the hook returns the Claude Code
# `permissionDecision: deny` shape naming the policy violation and the
# decision id (Plugin Batch 1 richer context).
#
# The seed is `rm -rf / --no-preserve-root`, which AxonFlow v11.0.0 blocks
# (sys__dangerous__destructive__fs). The SQL injection string this smoke used
# to seed is ALLOWED by v11.0.0 everywhere but /api/request, and v11.0.0 sends
# no risk level, so the old `risk:` marker could never appear.
#
# Scope: smoke-only — install wiring + one local deny UX.
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
FIXTURE="$REPO_ROOT/tests/fixtures/claude-code-hook-json/bash-pre.json"

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

INPUT=$(jq -c '.tool_input.command = "rm -rf / --no-preserve-root"' "$FIXTURE")

OUTPUT=$(printf '%s' "$INPUT" | bash "$HOOK_SCRIPT" 2>/dev/null)
EXIT_CODE=$?
echo "--- exit code: $EXIT_CODE ---"
echo "--- hook output ---"
echo "$OUTPUT"
echo "---"

errors=0
if [ "$EXIT_CODE" != "0" ]; then
  echo "FAIL: expected exit 0 (Claude Code reads the deny from stdout), got $EXIT_CODE"
  errors=$((errors + 1))
fi
if ! printf '%s' "$OUTPUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  echo "FAIL: expected .hookSpecificOutput.permissionDecision == \"deny\""
  errors=$((errors + 1))
fi

REASON=$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)
echo "permission decision reason: $REASON"

if ! grep -q "AxonFlow policy violation" <<<"$REASON"; then
  echo "FAIL: reason missing the 'AxonFlow policy violation' prefix"
  errors=$((errors + 1))
fi
if ! grep -qE "decision: [0-9a-f-]{36}" <<<"$REASON"; then
  echo "FAIL: reason missing 'decision: <id>' (Plugin Batch 1 richer context)"
  errors=$((errors + 1))
fi

if [ $errors -gt 0 ]; then
  echo "FAIL: smoke scenario failed with $errors error(s)"
  exit 1
fi
echo "PASS: smoke — Claude Code hook denies a destructive Bash command with the decision id"
