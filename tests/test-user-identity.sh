#!/usr/bin/env bash
# Unit test for scripts/user-identity.sh — per-developer identity (issue #2754).
#
# Asserts the resolution precedence the plugin sends as X-User-Email:
#   1. AXONFLOW_USER_EMAIL env var wins.
#   2. `git config user.email` best-effort fallback when the env var is absent.
#   3. neither → empty (no header shipped).
# Plus: env wins over git, and CR/LF/whitespace is stripped (header-split guard).
#
# Stdlib-only (bash + git). No live AxonFlow stack required.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${PLUGIN_DIR}/scripts/user-identity.sh"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

# resolve_in_env runs resolve_user_identity in a clean subshell with a given
# env + working dir and echoes AXONFLOW_USER_EMAIL_RESOLVED. $1=workdir, rest
# are `VAR=value` assignments applied via env.
resolve_in_env() {
  local wd="$1"; shift
  ( cd "$wd" && env -u AXONFLOW_USER_EMAIL -u AXONFLOW_USER_EMAIL_RESOLVED "$@" \
      bash -c '. "'"$SCRIPT_PATH"'"; resolve_user_identity; printf "%s" "${AXONFLOW_USER_EMAIL_RESOLVED:-}"' )
}

# A directory with NO git identity: a fresh repo with no user.email, plus an
# empty HOME so no global git config leaks in.
NOGIT_HOME="$(mktemp -d)"
NOGIT_REPO="$(mktemp -d)"
git -C "$NOGIT_REPO" init -q >/dev/null 2>&1 || true

# A directory WITH a repo-local git identity.
GIT_REPO="$(mktemp -d)"
git -C "$GIT_REPO" init -q >/dev/null 2>&1 || true
git -C "$GIT_REPO" config user.email "gituser@example.com"

cleanup() { rm -rf "$NOGIT_HOME" "$NOGIT_REPO" "$GIT_REPO"; }
trap cleanup EXIT

# Test 1: env var wins.
OUT=$(resolve_in_env "$NOGIT_REPO" HOME="$NOGIT_HOME" AXONFLOW_USER_EMAIL="alice@example.com")
if [ "$OUT" = "alice@example.com" ]; then
  pass "AXONFLOW_USER_EMAIL env → resolved verbatim"
else
  fail "env case: got '$OUT', want 'alice@example.com'"
fi

# Test 2: git fallback when env unset.
OUT=$(resolve_in_env "$GIT_REPO" HOME="$NOGIT_HOME")
if [ "$OUT" = "gituser@example.com" ]; then
  pass "no env, git config user.email → best-effort fallback"
else
  fail "git-fallback case: got '$OUT', want 'gituser@example.com'"
fi

# Test 3: neither → empty (no header).
OUT=$(resolve_in_env "$NOGIT_REPO" HOME="$NOGIT_HOME")
if [ -z "$OUT" ]; then
  pass "no env + no git identity → empty (X-User-Email omitted)"
else
  fail "empty case: expected empty, got '$OUT'"
fi

# Test 4: env wins over git (both present).
OUT=$(resolve_in_env "$GIT_REPO" HOME="$NOGIT_HOME" AXONFLOW_USER_EMAIL="env-wins@example.com")
if [ "$OUT" = "env-wins@example.com" ]; then
  pass "env takes precedence over git config"
else
  fail "precedence case: got '$OUT', want 'env-wins@example.com'"
fi

# Test 5: CR/LF + whitespace stripped (header-injection guard). A value with an
# embedded newline must not survive as a second header line.
INJECT=$'  bob@example.com\r\nEvil: injected  '
OUT=$(resolve_in_env "$NOGIT_REPO" HOME="$NOGIT_HOME" AXONFLOW_USER_EMAIL="$INJECT")
case "$OUT" in
  *$'\n'*|*$'\r'*) fail "sanitize case: CR/LF survived: $(printf '%q' "$OUT")" ;;
  *" "*)          fail "sanitize case: whitespace survived: '$OUT'" ;;
  "bob@example.comEvil:injected") pass "CR/LF + whitespace stripped (no header split)" ;;
  *)              fail "sanitize case: unexpected '$OUT'" ;;
esac

# Test 6: works under set -u (hook scripts run with -u semantics on vars).
if (set -u; env -u AXONFLOW_USER_EMAIL bash -c '. "'"$SCRIPT_PATH"'"; resolve_user_identity; echo "${AXONFLOW_USER_EMAIL_RESOLVED:-}" >/dev/null') 2>/dev/null; then
  pass "user-identity.sh works under set -u"
else
  fail "user-identity.sh trips set -u"
fi

echo ""
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
