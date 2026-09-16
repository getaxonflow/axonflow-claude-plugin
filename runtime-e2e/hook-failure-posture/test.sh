#!/usr/bin/env bash
# hook-failure-posture: runtime E2E for the Claude Code plugin hooks' failure posture.
#
# Fires the plugin's REAL hook scripts (scripts/pre-tool-check.sh and
# scripts/post-tool-audit.sh) with the hook JSON Claude Code sends on stdin
# (captured from Claude Code 2.1.273, tests/fixtures/claude-code-hook-json/),
# the way Claude Code runs them, against a REAL AxonFlow stack and against an
# endpoint nothing listens on. No mocks, no stubs. Leg 5 can admit up to 5 new
# client ids on a community stack below its service-principal ceiling. See
# README.md.
#
# Claude Code reads a hook's answer from stdout on exit 0: a block is
# hookSpecificOutput.permissionDecision "deny"; a notice the user sees is the
# top-level systemMessage (stderr on exit 0 is not shown); an alert for the
# model is hookSpecificOutput.additionalContext.
#
# Usage: AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/hook-failure-posture/test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"
POST_HOOK="$PLUGIN_DIR/scripts/post-tool-audit.sh"
FIXTURES="$PLUGIN_DIR/tests/fixtures/claude-code-hook-json"
# shellcheck source=../_lib/claude-runtime.sh
source "$PLUGIN_DIR/runtime-e2e/_lib/claude-runtime.sh"

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
EVIDENCE="${AXONFLOW_E2E_EVIDENCE_DIR:-$(mktemp -d -t hook-failure-posture.XXXXXX)}"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== Hook failure posture (Claude Code hooks) ==="
echo "Endpoint: $ENDPOINT"
echo "Evidence: $EVIDENCE"
mkdir -p "$EVIDENCE" || exit 1

for tool in curl jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not on PATH"
    exit 0
  fi
done
runtime_e2e_refuse_production "$ENDPOINT" "fires hooks that send governed checks and, in leg 5, admits up to five new client ids"
if ! curl -sSf -o /dev/null --max-time 5 "$ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $ENDPOINT"
  exit 0
fi

# A port nothing listens on: bind one, then release it.
DEAD_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
DEAD_ENDPOINT="http://127.0.0.1:${DEAD_PORT}"

SANDBOX="$EVIDENCE/sandbox"
mkdir -p "$SANDBOX/home/.config/axonflow" || exit 1

# fire <hook> <tag> <endpoint> <hook JSON> [NAME=VALUE ...]: runs the hook the
# way Claude Code does, as a subprocess with the hook JSON on stdin, in a
# sandbox home with its own cache, and keeps what it saw.
fire() {
  local hook="$1" tag="$2" endpoint="$3" json="$4"
  shift 4
  printf '%s' "$json" > "$EVIDENCE/$tag.stdin.json"
  (
    cd "$PLUGIN_DIR" || exit 97
    env -u AXONFLOW_USER_TOKEN -u AXONFLOW_LICENSE_TOKEN -u AXONFLOW_PEP_AUDIENCE -u AXONFLOW_MODE \
        -u AXONFLOW_FAIL_MODE -u AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR -u AXONFLOW_USER_EMAIL \
      HOME="$SANDBOX/home" AXONFLOW_CONFIG_DIR="$SANDBOX/home/.config/axonflow" XDG_CACHE_HOME="$SANDBOX/cache-$tag" \
      AXONFLOW_ENDPOINT="$endpoint" AXONFLOW_AUTH="" \
      AXONFLOW_TELEMETRY=off AXONFLOW_PLUGIN_VERSION_CHECK=off AXONFLOW_IDENTITY_NOTICE=off \
      "$@" bash "$hook"
  ) < "$EVIDENCE/$tag.stdin.json" > "$EVIDENCE/$tag.stdout" 2> "$EVIDENCE/$tag.stderr"
  echo "$?" > "$EVIDENCE/$tag.rc"
}

pre_json() { jq -c --arg c "$1" '.tool_input.command = $c' "$FIXTURES/bash-pre.json"; }
post_json() { jq -c --arg o "$1" '.tool_response.stdout = $o' "$FIXTURES/bash-post.json"; }
rc() { cat "$EVIDENCE/$1.rc"; }
decision() { jq -r '.hookSpecificOutput.permissionDecision // empty' "$EVIDENCE/$1.stdout" 2>/dev/null; }
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$EVIDENCE/$1.stdout" 2>/dev/null; }
notice() { jq -r '.systemMessage // empty' "$EVIDENCE/$1.stdout" 2>/dev/null; }
context() { jq -r '.hookSpecificOutput.additionalContext // empty' "$EVIDENCE/$1.stdout" 2>/dev/null; }
contains() { grep -qF -- "$2" <<<"$1"; }

NOTICE="GOVERNANCE UNAVAILABLE"

echo ""
echo "--- 1. the platform decides: an allow and a deny ---"
fire "$PRE_HOOK" pre-allow "$ENDPOINT" "$(pre_json "echo hook-failure-posture")"
if [ "$(rc pre-allow)" = 0 ] && [ ! -s "$EVIDENCE/pre-allow.stdout" ]; then
  pass "an allowed command runs (exit 0, nothing on stdout: no deny, no notice)"
else
  fail "an allowed command: exit $(rc pre-allow), stdout: $(cat "$EVIDENCE/pre-allow.stdout")"
fi
fire "$PRE_HOOK" pre-deny "$ENDPOINT" "$(pre_json "rm -rf / --no-preserve-root")"
if [ "$(rc pre-deny)" = 0 ] && [ "$(decision pre-deny)" = deny ] && contains "$(reason pre-deny)" "AxonFlow policy violation"; then
  pass "a destructive command is denied: $(reason pre-deny | cut -c1-160)"
else
  fail "a destructive command: exit $(rc pre-deny), stdout: $(cat "$EVIDENCE/pre-deny.stdout")"
fi

echo ""
echo "--- 2. no answer, AXONFLOW_FAIL_MODE unset: the tool call runs, and the user is told ---"
fire "$PRE_HOOK" pre-down "$DEAD_ENDPOINT" "$(pre_json "echo hook-failure-posture down")"
if [ "$(rc pre-down)" = 0 ] && [ -z "$(decision pre-down)" ] && contains "$(notice pre-down)" "$NOTICE" && contains "$(notice pre-down)" "This tool call runs UNGOVERNED"; then
  pass "unreachable: runs with the notice in systemMessage: $(notice pre-down | cut -c1-140)"
else
  fail "unreachable, fail mode unset: exit $(rc pre-down), stdout: $(cat "$EVIDENCE/pre-down.stdout")"
fi
fire "$POST_HOOK" post-down "$DEAD_ENDPOINT" "$(post_json "total 0")"
if [ "$(rc post-down)" = 0 ] && [ -z "$(context post-down)" ] && contains "$(notice post-down)" "This tool output was NOT checked"; then
  pass "unreachable (post): the output passes with the notice in systemMessage, and no alert"
else
  fail "unreachable (post): exit $(rc post-down), stdout: $(cat "$EVIDENCE/post-down.stdout")"
fi

echo ""
echo "--- 3. no answer, AXONFLOW_FAIL_MODE=closed: denied ---"
fire "$PRE_HOOK" pre-down-closed "$DEAD_ENDPOINT" "$(pre_json "echo hook-failure-posture closed")" AXONFLOW_FAIL_MODE=closed
if [ "$(rc pre-down-closed)" = 0 ] && [ "$(decision pre-down-closed)" = deny ] && contains "$(reason pre-down-closed)" 'AXONFLOW_FAIL_MODE is "closed"'; then
  pass "unreachable under closed: denied: $(reason pre-down-closed | cut -c1-140)"
else
  fail "unreachable under closed: exit $(rc pre-down-closed), stdout: $(cat "$EVIDENCE/pre-down-closed.stdout")"
fi
fire "$POST_HOOK" post-down-closed "$DEAD_ENDPOINT" "$(post_json "total 0")" AXONFLOW_FAIL_MODE=closed
if [ "$(rc post-down-closed)" = 0 ] && contains "$(context post-down-closed)" "could not check this tool output"; then
  pass "unreachable under closed (post): the governance alert withholds the output"
else
  fail "unreachable under closed (post): stdout: $(cat "$EVIDENCE/post-down-closed.stdout")"
fi

echo ""
echo "--- 4. the switches never loosen a decision ---"
fire "$PRE_HOOK" pre-deny-open "$ENDPOINT" "$(pre_json "rm -rf / --no-preserve-root")" AXONFLOW_FAIL_MODE=open AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1
if [ "$(decision pre-deny-open)" = deny ] && contains "$(reason pre-deny-open)" "AxonFlow policy violation"; then
  pass "a deny under AXONFLOW_FAIL_MODE=open and AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1 is still denied"
else
  fail "a deny under both switches: stdout: $(cat "$EVIDENCE/pre-deny-open.stdout")"
fi

echo ""
echo "--- 5. a live 401 from the agent: denied, the cooldown stamped, the output withheld ---"
# A community agent checks no client secret. The one 401 it gives is its MCP
# server's answer to a client id the organization has not admitted, once the
# organization has admitted its service-principal ceiling (5 on the community
# edition): 401 -32001 "Authentication required", where the REST routes answer
# 402 (getaxonflow/axonflow-enterprise#4249, comment 5682255301). So this leg
# first sends one request as this suite's own client (no credential), keeping
# that client admitted, then new client ids until the MCP server refuses one:
# at most 5 requests. On a stack below its ceiling those requests ADMIT new
# client ids, and a later suite presenting a client id not yet admitted is
# then refused. That is the price of a live 401 on this edition.
mcp_status_as() {  # mcp_status_as <client id, or empty for no credential>
  local auth_args=()
  if [ -n "$1" ]; then
    auth_args=(-H "Authorization: Basic $(printf '%s:hook-failure-posture' "$1" | base64 | tr -d '\n')")
  fi
  curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST "$ENDPOINT/api/v1/mcp-server" \
    -H "Content-Type: application/json" ${auth_args[@]+"${auth_args[@]}"} \
    -d '{"jsonrpc":"2.0","id":"hook-failure-posture","method":"tools/call","params":{"name":"check_policy","arguments":{"connector_type":"claude_code.Bash","statement":"echo hook-failure-posture","operation":"execute"}}}'
}
OWN_STATUS=$(mcp_status_as "")
UNADMITTED=""
for i in 1 2 3 4 5; do
  candidate="hfp-unadmitted-$(date +%s)-$$-$i"
  if [ "$(mcp_status_as "$candidate")" = "401" ]; then
    UNADMITTED="$candidate"
    break
  fi
done
if [ -z "$UNADMITTED" ]; then
  fail "no live 401: this suite's own client answered HTTP $OWN_STATUS and 5 new client ids were all admitted (a community stack refuses the next one past its ceiling)"
else
  echo "(the MCP server refused client id $UNADMITTED with HTTP 401)"
  AUTH_401=$(printf '%s:hook-failure-posture' "$UNADMITTED" | base64 | tr -d '\n')
  CACHE_401="$SANDBOX/cache-live-401"

  fire "$PRE_HOOK" pre-401 "$ENDPOINT" "$(pre_json "echo hook-failure-posture 401")" AXONFLOW_AUTH="$AUTH_401" XDG_CACHE_HOME="$CACHE_401"
  if [ "$(decision pre-401)" = deny ] && contains "$(reason pre-401)" 'authentication error ("Authentication required", code -32001)'; then
    pass "a live 401 is denied with the platform's words: $(reason pre-401 | cut -c1-160)"
  else
    fail "a live 401: exit $(rc pre-401), stdout: $(cat "$EVIDENCE/pre-401.stdout")"
  fi
  if grep -q "auth_failure" "$CACHE_401/axonflow/throttle-until" 2>/dev/null; then
    pass "the live 401 stamped the auth_failure cooldown"
  else
    fail "the live 401 stamped no auth_failure cooldown: $(cat "$CACHE_401/axonflow/throttle-until" 2>/dev/null)"
  fi

  fire "$PRE_HOOK" pre-401-cooldown "$ENDPOINT" "$(pre_json "echo hook-failure-posture cooldown")" AXONFLOW_AUTH="$AUTH_401" XDG_CACHE_HOME="$CACHE_401" AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1
  if [ "$(decision pre-401-cooldown)" = deny ] && contains "$(reason pre-401-cooldown)" "auth-failure cooldown is active" && contains "$(reason pre-401-cooldown)" "stay blocked for another"; then
    pass "the cooldown denies the next call, even with the break-glass set, naming the seconds left and the stamp file"
  else
    fail "the cooldown: stdout: $(cat "$EVIDENCE/pre-401-cooldown.stdout")"
  fi

  fire "$PRE_HOOK" pre-401-open "$ENDPOINT" "$(pre_json "echo hook-failure-posture 401 open")" AXONFLOW_AUTH="$AUTH_401" AXONFLOW_FAIL_MODE=open
  if [ "$(decision pre-401-open)" = deny ] && contains "$(reason pre-401-open)" "code -32001"; then
    pass "a live 401 under AXONFLOW_FAIL_MODE=open is still denied, as a rejected credential"
  else
    fail "a live 401 under open: stdout: $(cat "$EVIDENCE/pre-401-open.stdout")"
  fi

  # The documented break-glass: the -32001 401 runs, the user sees the switch named, nothing is stamped.
  fire "$PRE_HOOK" pre-401-breakglass "$ENDPOINT" "$(pre_json "echo hook-failure-posture breakglass")" AXONFLOW_AUTH="$AUTH_401" AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1
  if [ "$(rc pre-401-breakglass)" = 0 ] && [ -z "$(decision pre-401-breakglass)" ] && contains "$(notice pre-401-breakglass)" "AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR is set" \
     && [ ! -f "$SANDBOX/cache-pre-401-breakglass/axonflow/throttle-until" ]; then
    pass "a live 401 under AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1 runs, with the switch named in systemMessage, and stamps no cooldown"
  else
    fail "a live 401 under the break-glass: exit $(rc pre-401-breakglass), stdout: $(cat "$EVIDENCE/pre-401-breakglass.stdout")"
  fi

  fire "$POST_HOOK" post-401 "$ENDPOINT" "$(post_json "total 0")" AXONFLOW_AUTH="$AUTH_401"
  if [ "$(rc post-401)" = 0 ] && contains "$(context post-401)" "rejected authentication, HTTP 401"; then
    pass "a live 401 (post): the governance alert withholds the output"
  else
    fail "a live 401 (post): exit $(rc post-401), stdout: $(cat "$EVIDENCE/post-401.stdout")"
  fi
fi

echo ""
echo "=== Hook failure posture (Claude Code hooks): $PASS passed, $FAIL failed ==="
echo "Evidence: $EVIDENCE"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
