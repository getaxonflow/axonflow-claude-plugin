#!/usr/bin/env bash
# free-tier-cap-deny: runtime E2E for the Claude Code plugin hooks.
#
# Fires the plugin's REAL hook scripts (scripts/pre-tool-check.sh and
# scripts/post-tool-audit.sh) with Claude Code's hook JSON on stdin against a REAL
# local AxonFlow stack in Community SaaS mode. A freshly registered Free
# tenant is pushed past its per-minute limit by the hooks' own MCP calls: no
# mocks, no stubs, no recorded responses. See README.md.
#
# Usage: AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/free-tier-cap-deny/test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"
POST_HOOK="$PLUGIN_DIR/scripts/post-tool-audit.sh"

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
MAX_CALLS="${AXONFLOW_E2E_CAP_MAX_CALLS:-60}"
EVIDENCE="${AXONFLOW_E2E_EVIDENCE_DIR:-$(mktemp -d -t free-tier-cap-deny.XXXXXX)}"

# The texts the hooks use over the limit (scripts/upgrade-prompt.sh), and the
# upgrade prompt's own line, which the block reason never contains.
LIMIT_REASON="reached its Free-tier limit"
POST_ALERT="could not check this tool output"
PROMPT_LINE="[AxonFlow] Upgrade: "

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== Free-tier cap deny (Claude Code hooks) ==="
echo "Endpoint: $ENDPOINT"
echo "Evidence: $EVIDENCE"
mkdir -p "$EVIDENCE" || exit 1

for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not on PATH"
    exit 0
  fi
done
if ! curl -sSf -o /dev/null --max-time 5 "$ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $ENDPOINT"
  exit 0
fi

# A fresh Free tenant through the Community SaaS registration route, which
# exists only in community-saas mode. The secret is a credential: it stays in
# this shell and is never printed or written.
REG_LABEL="free-tier-cap-deny-claude-$(date +%s)-$RANDOM"
REG=$(curl -s -w '\n%{http_code}' -X POST "$ENDPOINT/api/v1/register" \
  -H 'Content-Type: application/json' \
  -d "{\"label\":\"$REG_LABEL\",\"email\":\"$REG_LABEL@axonflow-test.invalid\"}")
REG_CODE="${REG##*$'\n'}"
REG_JSON="${REG%$'\n'*}"
if [ "$REG_CODE" = "404" ]; then
  echo "SKIP: /api/v1/register answered 404, so this stack is not in community-saas mode"
  echo "      (docker compose -f docker-compose.yml -f docker-compose.community-saas.yml up -d)"
  exit 0
fi
TENANT_ID=$(printf '%s' "$REG_JSON" | jq -r '.tenant_id // empty' 2>/dev/null)
SECRET=$(printf '%s' "$REG_JSON" | jq -r '.secret // empty' 2>/dev/null)
if [ -z "$TENANT_ID" ] || [ -z "$SECRET" ]; then
  echo "FAIL: registration answered HTTP $REG_CODE without a tenant_id and secret"
  echo "  body: $(printf '%s' "$REG_JSON" | jq -c 'del(.secret?)' 2>/dev/null | cut -c1-300)"
  exit 1
fi
AUTH_B64=$(printf '%s:%s' "$TENANT_ID" "$SECRET" | base64 | tr -d '\n')
unset SECRET REG REG_JSON
pass "registered Free tenant $TENANT_ID (HTTP $REG_CODE; the secret is not printed)"

SANDBOX="$EVIDENCE/sandbox"
mkdir -p "$SANDBOX/home/.config/axonflow" || exit 1

# fire <hook> <tag> <cache dir> <hook JSON>: runs the hook the way Claude Code
# does, as a subprocess with the hook JSON on stdin, and keeps what it saw.
fire() {
  local hook="$1" tag="$2" cache="$3"
  printf '%s' "$4" > "$EVIDENCE/$tag.stdin.json"
  (
    cd "$PLUGIN_DIR" || exit 97
    env -u AXONFLOW_USER_TOKEN -u AXONFLOW_LICENSE_TOKEN -u AXONFLOW_PEP_AUDIENCE -u AXONFLOW_MODE \
      HOME="$SANDBOX/home" AXONFLOW_CONFIG_DIR="$SANDBOX/home/.config/axonflow" XDG_CACHE_HOME="$cache" \
      AXONFLOW_ENDPOINT="$ENDPOINT" AXONFLOW_AUTH="$AUTH_B64" \
      AXONFLOW_TELEMETRY=off AXONFLOW_PLUGIN_VERSION_CHECK=off AXONFLOW_IDENTITY_NOTICE=off \
      bash "$hook"
  ) < "$EVIDENCE/$tag.stdin.json" > "$EVIDENCE/$tag.stdout" 2> "$EVIDENCE/$tag.stderr"
  echo "$?" > "$EVIDENCE/$tag.rc"
}

pre_json() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}, session_id: "free-tier-cap-deny"}'; }
post_json() { jq -nc --arg o "$1" '{tool_name: "Bash", tool_input: {command: "cat notes.txt"}, tool_response: {stdout: $o, exitCode: 0}, session_id: "free-tier-cap-deny"}'; }
# Claude Code blocks on a permissionDecision "deny" object on stdout (exit 0).
is_block() { [ "$(cat "$EVIDENCE/$1.rc")" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$EVIDENCE/$1.stdout" >/dev/null 2>&1; }
block_reason() { jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$EVIDENCE/$1.stdout" 2>/dev/null; }
is_allow() { [ "$(cat "$EVIDENCE/$1.rc")" = 0 ] && ! is_block "$1"; }
post_alert() { jq -r '.hookSpecificOutput.additionalContext // empty' "$EVIDENCE/$1.stdout" 2>/dev/null; }

# trip <cache dir> <tag prefix>: fires the pre hook with a harmless command
# until it blocks. Sets ALLOWED and BLOCK_TAG.
trip() {
  local cache="$1" prefix="$2" i tag
  ALLOWED=0
  BLOCK_TAG=""
  for i in $(seq 1 "$MAX_CALLS"); do
    tag=$(printf '%s-%02d' "$prefix" "$i")
    fire "$PRE_HOOK" "$tag" "$cache" "$(pre_json "echo free-tier-cap-deny $i")"
    if is_block "$tag"; then
      BLOCK_TAG="$tag"
      return 0
    fi
    if ! is_allow "$tag"; then
      echo "  $tag: exit $(cat "$EVIDENCE/$tag.rc"), neither an allow nor a block"
      return 1
    fi
    ALLOWED=$((ALLOWED + 1))
    sleep 1   # the pre hook backgrounds an audit call; let it land
  done
  return 1
}

# post_over_limit <cache dir> <tag>: 0 when the post hook raised the alert.
post_over_limit() {
  fire "$POST_HOOK" "$2" "$1" "$(post_json "total 0")"
  case "$(post_alert "$2")" in
    *"$POST_ALERT"*) return 0 ;;
  esac
  return 1
}

echo ""
echo "--- 1. the pre hook, under the limit and then over it ---"
CACHE1="$SANDBOX/cache-1"
if ! trip "$CACHE1" pre; then
  fail "no block within $MAX_CALLS pre-hook calls ($ALLOWED allowed)"
else
  if [ "$ALLOWED" -ge 1 ]; then
    pass "$ALLOWED pre-hook call(s) allowed under the limit before the first block"
  else
    fail "the first pre-hook call was already blocked: $(block_reason "$BLOCK_TAG" | head -1)"
  fi
  REASON=$(block_reason "$BLOCK_TAG")
  case "$REASON" in
    *"$LIMIT_REASON"*) pass "$BLOCK_TAG blocked, naming the limit: $(printf '%s\n' "$REASON" | grep -F "$LIMIT_REASON" | head -1)" ;;
    *) fail "$BLOCK_TAG blocked, but the reason does not name the Free-tier limit: $REASON" ;;
  esac
  if grep -qF "$PROMPT_LINE" "$EVIDENCE/$BLOCK_TAG.stderr"; then
    pass "the upgrade prompt printed with the block: $(grep -B1 -F "$PROMPT_LINE" "$EVIDENCE/$BLOCK_TAG.stderr" | head -1)"
  else
    fail "no upgrade prompt ($PROMPT_LINE...) on the blocking call's stderr"
  fi
  THROTTLE="$CACHE1/axonflow/throttle-until"
  if [ -f "$THROTTLE" ]; then
    DEADLINE=$(awk 'NR==1 {print $1}' "$THROTTLE")
    LIMIT_TYPE=$(awk 'NR==1 {print $2}' "$THROTTLE")
    NOW=$(date -u +%s)
    if [ "${DEADLINE:-0}" -gt "$NOW" ] && [ -n "$LIMIT_TYPE" ] && [ "$LIMIT_TYPE" != "auth_failure" ]; then
      pass "the back-off is stamped: limit_type=$LIMIT_TYPE, $((DEADLINE - NOW)) s ahead"
    else
      fail "the throttle stamp is not a Free-tier back-off: $(cat "$THROTTLE")"
    fi
  else
    fail "no throttle-until stamp in $CACHE1/axonflow"
  fi
fi

if [ -n "$BLOCK_TAG" ]; then
  echo ""
  echo "--- 2. the platform's answer over the limit (recorded, not asserted) ---"
  OBS_CODE=$(curl -s -o "$EVIDENCE/observed-answer.json" -w '%{http_code}' -X POST "$ENDPOINT/api/v1/mcp-server" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' -H "Authorization: Basic $AUTH_B64" \
    -d '{"jsonrpc":"2.0","id":"observe","method":"tools/call","params":{"name":"check_policy","arguments":{"connector_type":"shell","statement":"echo observe","operation":"execute"}}}')
  echo "OBSERVED: HTTP $OBS_CODE, result.isError=$(jq -r '.result.isError // false' "$EVIDENCE/observed-answer.json" 2>/dev/null), limit_type=$(jq -r '((.result.content[0].text // "{}") | fromjson? | .limit_type) // .limit_type // empty' "$EVIDENCE/observed-answer.json" 2>/dev/null)"

  echo ""
  echo "--- 3. the post hook's own check over the limit ---"
  if post_over_limit "$SANDBOX/cache-2" post-net; then
    pass "the post hook alerted over the limit: $(post_alert post-net)"
  else
    # The per-minute window can roll over between the block and this call;
    # reach the limit once more and check again straight away.
    echo "  post-net passed the output (exit $(cat "$EVIDENCE/post-net.rc")); reaching the limit again"
    if trip "$SANDBOX/cache-3" pre-again && post_over_limit "$SANDBOX/cache-4" post-net-again; then
      pass "the post hook alerted over the limit: $(post_alert post-net-again)"
    else
      fail "the post hook did not alert over the limit (see post-net*.stdout)"
    fi
  fi

  echo ""
  echo "--- 4. while the back-off holds ---"
  fire "$PRE_HOOK" pre-held "$CACHE1" "$(pre_json "echo free-tier-cap-deny held")"
  if is_block pre-held && block_reason pre-held | grep -qF "$LIMIT_REASON"; then
    pass "the pre hook blocks while the back-off holds"
  else
    fail "the pre hook did not block while the back-off holds (exit $(cat "$EVIDENCE/pre-held.rc"))"
  fi
  fire "$POST_HOOK" post-held "$CACHE1" "$(post_json "total 0")"
  case "$(post_alert post-held)" in
    *"$POST_ALERT"*"Free-tier limit"*) pass "the post hook alerts while the back-off holds: $(post_alert post-held)" ;;
    *) fail "the post hook did not alert while the back-off holds: $(cat "$EVIDENCE/post-held.stdout")" ;;
  esac
fi

echo ""
echo "=== Free-tier cap deny (Claude Code hooks): $PASS passed, $FAIL failed ==="
echo "Evidence: $EVIDENCE"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
