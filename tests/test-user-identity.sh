#!/usr/bin/env bash
# Unit test for scripts/user-identity.sh — per-developer identity (issue
# #2754; identity-absent hardening #2836).
#
# Asserts the resolution precedence the plugin sends as X-User-Email:
#   1. AXONFLOW_USER_EMAIL env var wins (set-but-blank falls through).
#   2. `git config user.email` best-effort fallback when the env var is
#      absent — merged read from cwd first (repo-local wins), then an explicit
#      --global read that survives a corrupt .git/config or a deleted cwd.
#   3. neither → empty (no header shipped) + a once-per-day stderr diagnostic
#      explaining why (suppressible with AXONFLOW_IDENTITY_NOTICE=off).
# Plus: env wins over git, CR/LF/whitespace is stripped (header-split guard),
# and AXONFLOW_USER_IDENTITY_SOURCE reports env|git|none.
#
# Stdlib-only (bash + git). No live AxonFlow stack required.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${PLUGIN_DIR}/scripts/user-identity.sh"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

WORK="$(mktemp -d)"
RESOLVE_STDERR="$WORK/resolve-stderr"

# resolve_in_env runs resolve_user_identity in a clean subshell with a given
# env + working dir and echoes AXONFLOW_USER_EMAIL_RESOLVED. $1=workdir, rest
# are `VAR=value` assignments applied via env. GIT_CONFIG_NOSYSTEM keeps a
# host /etc/gitconfig from leaking into the merged read. Stderr (the identity
# diagnostic) is captured to $RESOLVE_STDERR for assertion.
resolve_in_env() {
  local wd="$1"; shift
  ( cd "$wd" && env -u AXONFLOW_USER_EMAIL -u AXONFLOW_USER_EMAIL_RESOLVED \
      -u AXONFLOW_USER_IDENTITY_SOURCE GIT_CONFIG_NOSYSTEM=1 "$@" \
      bash -c '. "'"$SCRIPT_PATH"'"; resolve_user_identity; printf "%s" "${AXONFLOW_USER_EMAIL_RESOLVED:-}"' ) 2>"$RESOLVE_STDERR"
}

# resolve_source_in_env — same, but echoes "<resolved>|<source>" so tests can
# assert AXONFLOW_USER_IDENTITY_SOURCE too.
resolve_source_in_env() {
  local wd="$1"; shift
  ( cd "$wd" && env -u AXONFLOW_USER_EMAIL -u AXONFLOW_USER_EMAIL_RESOLVED \
      -u AXONFLOW_USER_IDENTITY_SOURCE GIT_CONFIG_NOSYSTEM=1 "$@" \
      bash -c '. "'"$SCRIPT_PATH"'"; resolve_user_identity; printf "%s|%s" "${AXONFLOW_USER_EMAIL_RESOLVED:-}" "${AXONFLOW_USER_IDENTITY_SOURCE:-}"' ) 2>"$RESOLVE_STDERR"
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

# A plain directory that is NOT a git repo (identity-absent cwd).
NONREPO="$(mktemp -d)"

# A global gitconfig file (wired in via GIT_CONFIG_GLOBAL where a test wants a
# deterministic global identity).
GLOBAL_CFG="$WORK/globalconfig"
printf '[user]\n\temail = globaluser@example.com\n' > "$GLOBAL_CFG"

cleanup() { rm -rf "$WORK" "$NOGIT_HOME" "$NOGIT_REPO" "$GIT_REPO" "$NONREPO"; }
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
OUT=$(resolve_in_env "$NOGIT_REPO" HOME="$NOGIT_HOME" GIT_CONFIG_GLOBAL=/dev/null)
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
# HOME is pinned to the empty test HOME so the notice path (if reached on a
# host with no git identity) can never stamp the real ~/.cache.
if (set -u; env -u AXONFLOW_USER_EMAIL HOME="$NOGIT_HOME" bash -c '. "'"$SCRIPT_PATH"'"; resolve_user_identity; echo "${AXONFLOW_USER_EMAIL_RESOLVED:-}" >/dev/null') 2>/dev/null; then
  pass "user-identity.sh works under set -u"
else
  fail "user-identity.sh trips set -u"
fi

# --- #2836 hardening: the identity-ABSENT path (the real-world fleet state) ---

# Test 7: full identity-absent path — non-repo cwd, no env var, no git config
# anywhere. Must resolve empty, report source=none, and fire the stderr
# diagnostic naming AXONFLOW_USER_EMAIL so an admin can see WHY.
ABSENT_HOME="$(mktemp -d)"
OUT=$(resolve_source_in_env "$NONREPO" HOME="$ABSENT_HOME" GIT_CONFIG_GLOBAL=/dev/null)
DIAG="$(cat "$RESOLVE_STDERR" 2>/dev/null)"
if [ "$OUT" = "|none" ]; then
  pass "identity-absent (non-repo cwd, no env, no git config) → empty + source=none"
else
  fail "identity-absent case: got '$OUT', want '|none'"
fi
case "$DIAG" in
  *"No developer identity resolved"*AXONFLOW_USER_EMAIL*)
    pass "identity-absent diagnostic fires on stderr and names AXONFLOW_USER_EMAIL" ;;
  *)
    fail "identity-absent diagnostic missing/wrong: '$DIAG'" ;;
esac
rm -rf "$ABSENT_HOME"

# Test 8: diagnostic is once-per-day — second resolution with the same HOME
# stays silent (stamp file suppresses the repeat). A `date` shim pins the day
# so a run straddling UTC midnight cannot flake.
SHIMBIN="$WORK/shimbin"
mkdir -p "$SHIMBIN"
printf '#!/bin/sh\necho 2026-01-01\n' > "$SHIMBIN/date"
chmod +x "$SHIMBIN/date"
DAY_HOME="$(mktemp -d)"
resolve_in_env "$NONREPO" HOME="$DAY_HOME" PATH="$SHIMBIN:$PATH" GIT_CONFIG_GLOBAL=/dev/null >/dev/null
FIRST_DIAG="$(cat "$RESOLVE_STDERR" 2>/dev/null)"
resolve_in_env "$NONREPO" HOME="$DAY_HOME" PATH="$SHIMBIN:$PATH" GIT_CONFIG_GLOBAL=/dev/null >/dev/null
SECOND_DIAG="$(cat "$RESOLVE_STDERR" 2>/dev/null)"
if [ -n "$FIRST_DIAG" ] && [ -z "$SECOND_DIAG" ]; then
  pass "diagnostic throttled to once per day (stamp suppresses the repeat)"
else
  fail "diagnostic throttle: first='$FIRST_DIAG' second='$SECOND_DIAG'"
fi
rm -rf "$DAY_HOME"

# Test 9: AXONFLOW_IDENTITY_NOTICE=off suppresses the diagnostic entirely.
OFF_HOME="$(mktemp -d)"
resolve_in_env "$NONREPO" HOME="$OFF_HOME" GIT_CONFIG_GLOBAL=/dev/null AXONFLOW_IDENTITY_NOTICE=off >/dev/null
OFF_DIAG="$(cat "$RESOLVE_STDERR" 2>/dev/null)"
if [ -z "$OFF_DIAG" ]; then
  pass "AXONFLOW_IDENTITY_NOTICE=off suppresses the diagnostic"
else
  fail "notice=off case: diagnostic still fired: '$OFF_DIAG'"
fi
rm -rf "$OFF_HOME"

# Test 10: global-only git identity resolves from a NON-repo cwd (the merged
# read returns the global value outside a repo).
OUT=$(resolve_source_in_env "$NONREPO" HOME="$NOGIT_HOME" GIT_CONFIG_GLOBAL="$GLOBAL_CFG")
if [ "$OUT" = "globaluser@example.com|git" ]; then
  pass "global-only git identity resolves from a non-repo cwd"
else
  fail "global-only case: got '$OUT', want 'globaluser@example.com|git'"
fi

# Test 11: repo-local wins over global when both are set (matches git's own
# merged-config semantics).
OUT=$(resolve_in_env "$GIT_REPO" HOME="$NOGIT_HOME" GIT_CONFIG_GLOBAL="$GLOBAL_CFG")
if [ "$OUT" = "gituser@example.com" ]; then
  pass "repo-local git identity wins over global"
else
  fail "local-vs-global case: got '$OUT', want 'gituser@example.com'"
fi

# Test 12: corrupt .git/config — the merged read dies at the repo level, but
# the explicit --global read still recovers the global identity. This is the
# dubious-ownership / broken-repo class the pre-#2836 single merged read lost.
BROKEN_REPO="$(mktemp -d)"
git -C "$BROKEN_REPO" init -q >/dev/null 2>&1 || true
printf '[user\n' > "$BROKEN_REPO/.git/config"   # unclosed section → fatal: bad config
OUT=$(resolve_source_in_env "$BROKEN_REPO" HOME="$NOGIT_HOME" GIT_CONFIG_GLOBAL="$GLOBAL_CFG")
if [ "$OUT" = "globaluser@example.com|git" ]; then
  pass "corrupt .git/config → --global read still recovers the identity"
else
  fail "broken-repo case: got '$OUT', want 'globaluser@example.com|git'"
fi
rm -rf "$BROKEN_REPO"

# Test 13: deleted cwd — git cannot read the working directory, but the
# --global read (run from /) still recovers the identity.
DELETED_DIR="$(mktemp -d)"
OUT=$( { cd "$DELETED_DIR" && rm -rf "$DELETED_DIR" && \
  env -u AXONFLOW_USER_EMAIL -u AXONFLOW_USER_EMAIL_RESOLVED -u AXONFLOW_USER_IDENTITY_SOURCE \
    GIT_CONFIG_NOSYSTEM=1 HOME="$NOGIT_HOME" GIT_CONFIG_GLOBAL="$GLOBAL_CFG" \
    bash -c '. "'"$SCRIPT_PATH"'"; resolve_user_identity; printf "%s" "${AXONFLOW_USER_EMAIL_RESOLVED:-}"'; } 2>/dev/null )
if [ "$OUT" = "globaluser@example.com" ]; then
  pass "deleted cwd → --global read still recovers the identity"
else
  fail "deleted-cwd case: got '$OUT', want 'globaluser@example.com'"
fi

# Test 14: AXONFLOW_USER_EMAIL set but whitespace-only → falls through to the
# git fallback instead of silently suppressing the header.
OUT=$(resolve_source_in_env "$GIT_REPO" HOME="$NOGIT_HOME" AXONFLOW_USER_EMAIL="   ")
if [ "$OUT" = "gituser@example.com|git" ]; then
  pass "blank AXONFLOW_USER_EMAIL falls through to the git fallback"
else
  fail "blank-env case: got '$OUT', want 'gituser@example.com|git'"
fi

# Test 15: source var reports env|none correctly (git covered by T10/T12/T14).
OUT=$(resolve_source_in_env "$NOGIT_REPO" HOME="$NOGIT_HOME" AXONFLOW_USER_EMAIL="alice@example.com")
if [ "$OUT" = "alice@example.com|env" ]; then
  pass "AXONFLOW_USER_IDENTITY_SOURCE=env when the env var resolves"
else
  fail "source=env case: got '$OUT', want 'alice@example.com|env'"
fi

# Test 16: dubious-ownership repo — pinned with git's own test knob
# (GIT_TEST_ASSUME_DIFFERENT_OWNER, the mechanism git's t0033 uses). git
# SKIPS the repo-local config (does not die) and the merged read returns the
# global value; the repo-local email is deliberately lost per git's own
# safe-directory semantics.
OUT=$(resolve_source_in_env "$GIT_REPO" HOME="$NOGIT_HOME" \
  GIT_TEST_ASSUME_DIFFERENT_OWNER=true GIT_CONFIG_GLOBAL="$GLOBAL_CFG")
if [ "$OUT" = "globaluser@example.com|git" ]; then
  pass "dubious-ownership repo → git skips repo-local config, global resolves"
else
  fail "dubious-ownership case: got '$OUT', want 'globaluser@example.com|git'"
fi

# Test 17: stripped hook PATH (no git on PATH) — the standard-location probe
# finds the system git and resolution still succeeds. The shim PATH carries
# only bash + tr (what resolution itself needs); /usr/bin/git exists on both
# CI ubuntu and dev macs.
PROBEBIN="$WORK/probebin"
mkdir -p "$PROBEBIN"
ln -sf "$(command -v bash)" "$PROBEBIN/bash"
ln -sf "$(command -v tr)" "$PROBEBIN/tr"
if [ -x /usr/bin/git ]; then
  OUT=$(resolve_in_env "$NONREPO" HOME="$NOGIT_HOME" PATH="$PROBEBIN" GIT_CONFIG_GLOBAL="$GLOBAL_CFG")
  if [ "$OUT" = "globaluser@example.com" ]; then
    pass "stripped PATH (no git) → standard-location probe still resolves"
  else
    fail "stripped-PATH probe case: got '$OUT', want 'globaluser@example.com'"
  fi
else
  pass "stripped-PATH probe case skipped (/usr/bin/git absent on this host)"
fi

# Test 18: the Darwin /usr/bin/git Xcode-shim guard wiring. Deterministic
# directions: non-darwin OSTYPE never guards, and non-shim paths are never
# guarded even under darwin. The darwin+/usr/bin/git direction must agree
# with /usr/bin/xcode-select -p (pins that the guard consults it).
GUARD_OUT=$(bash -c '. "'"$SCRIPT_PATH"'"
  OSTYPE=linux-gnu; _axonflow_git_usable /usr/bin/git; r1=$?
  OSTYPE=darwin20; _axonflow_git_usable /opt/homebrew/bin/git; r2=$?
  OSTYPE=darwin20; _axonflow_git_usable /usr/bin/git; r3=$?
  if /usr/bin/xcode-select -p >/dev/null 2>&1; then want3=0; else want3=1; fi
  printf "%s %s %s %s" "$r1" "$r2" "$r3" "$want3"')
R1=${GUARD_OUT%% *}; REST=${GUARD_OUT#* }; R2=${REST%% *}; REST=${REST#* }; R3=${REST%% *}; WANT3=${REST#* }
if [ "$R1" = "0" ] && [ "$R2" = "0" ] && [ "$R3" = "$WANT3" ]; then
  pass "Xcode-shim guard: only darwin+/usr/bin/git is gated, via xcode-select"
else
  fail "shim-guard wiring: got r1=$R1 r2=$R2 r3=$R3 (want 0 0 $WANT3)"
fi

# Test 19: no usable git at all → the diagnostic names the git-unavailable
# reason. _axonflow_find_git is overridden AFTER sourcing (the one seam that
# forces this on hosts where the probe would otherwise find a system git);
# resolve_user_identity itself runs unmodified.
NOGIT_DIAG_HOME="$(mktemp -d)"
DIAG=$( env -u AXONFLOW_USER_EMAIL HOME="$NOGIT_DIAG_HOME" bash -c \
  '. "'"$SCRIPT_PATH"'"; _axonflow_find_git() { return 1; }; resolve_user_identity' 2>&1 )
case "$DIAG" in
  *"git fallback unavailable"*)
    pass "no usable git → diagnostic names the git-unavailable reason" ;;
  *)
    fail "no-usable-git reason missing: '$DIAG'" ;;
esac
rm -rf "$NOGIT_DIAG_HOME"

echo ""
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
