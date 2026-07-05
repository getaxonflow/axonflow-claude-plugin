#!/usr/bin/env bash
# Per-developer identity resolution for governed AxonFlow requests — issue
# #2754 (introduced), hardened for the identity-absent path in
# axonflow-enterprise#2836 (epic #2832).
#
# Sourced by the hooks (pre-tool-check.sh, post-tool-audit.sh) and the headers
# reference impl (mcp-auth-headers.sh) — never invoked. After sourcing and
# calling resolve_user_identity, two variables are exported:
#
#   AXONFLOW_USER_EMAIL_RESOLVED   the resolved developer email ("" when no
#                                  identity is available)
#   AXONFLOW_USER_IDENTITY_SOURCE  where it came from: "env" | "git" | "none"
#
# The plugin sends the email as the X-User-Email header on every governed
# agent request so the platform can attribute the audit row to a real person.
# Without it the agent falls back to a synthetic client-scoped id
# ("mcp-client:<org>") and the customer-portal User column shows the client,
# not a person — the exact degradation an unconfigured fleet hits
# (axonflow-enterprise#2832).
#
# Resolution order (canonical — must not change without a CHANGELOG entry):
#
#   1. AXONFLOW_USER_EMAIL env var — the SUPPORTED source. Claude Code does not
#      expose the logged-in Anthropic account email to hooks/plugins, so a
#      fleet sets this per developer via managed settings / MDM (#2762). A
#      value that sanitizes to empty (whitespace-only) falls through to the
#      git fallback instead of silently suppressing the header.
#   2. `git config user.email` — BEST-EFFORT last resort only. This is the git
#      identity, NOT the Anthropic account, so it can be silently wrong
#      (shared machine, service account, or simply unset). Read strategy
#      (#2836): first a merged read from the hook's cwd (repo-local value wins
#      inside a repo; outside a repo git still returns the global/system
#      value; in a dubious-ownership repo git itself skips the repo-local
#      config and returns the global value — verified with git's
#      GIT_TEST_ASSUME_DIFFERENT_OWNER knob), then an explicit `--global` read
#      that survives the failures the merged read dies on — a corrupt
#      .git/config or a deleted cwd. Resolution assumes coreutils (tr) on
#      PATH; the calling hooks already exit before resolution when jq/curl are
#      missing, so a PATH that strips coreutils never reaches this code.
#   3. Unset — no X-User-Email header is sent (the callers omit it entirely
#      rather than shipping an empty header). The agent then degrades to its
#      client-scoped synthetic id, never a hard NULL. A once-per-UTC-day
#      stderr notice explains WHY attribution degraded and how to fix it
#      (suppress with AXONFLOW_IDENTITY_NOTICE=off).
#
# Never exits non-zero. Never blocks the calling hook. Never writes to stdout
# (stdout is the hook protocol) — the diagnostic is stderr-only.

# _sanitize_user_email strips characters a valid email never contains but which
# could break a downstream sink: all whitespace (space/tab/CR/LF) defuses HTTP
# header-splitting, and the double-quote + backslash are removed so the value is
# safe to interpolate into the .mcp.json headersHelper's JSON output without
# escaping. Lossless for real addresses.
_sanitize_user_email() {
  printf '%s' "$1" | tr -d ' \t\r\n"\\'
}

# _axonflow_git_usable <path> — guard against the macOS /usr/bin/git Xcode
# shim: when no Command Line Tools / Xcode is installed, invoking it pops a
# GUI "install the developer tools?" dialog — never acceptable from a
# background hook (and the command fails anyway). Only trust /usr/bin/git on
# Darwin when xcode-select reports a developer directory. $OSTYPE is used
# instead of uname so the check works even with a stripped PATH.
_axonflow_git_usable() {
  case "$1" in
    /usr/bin/git)
      case "${OSTYPE:-}" in
        darwin*) /usr/bin/xcode-select -p >/dev/null 2>&1 || return 1 ;;
      esac
      ;;
  esac
  return 0
}

# _axonflow_find_git — print a usable git executable path, or nothing (rc 1).
# Hook environments occasionally run with a stripped PATH (managed-settings
# env blocks, MDM launch contexts), so when the PATH lookup fails we probe the
# standard install locations before giving up.
_axonflow_find_git() {
  local candidate found=""
  found="$(command -v git 2>/dev/null)" || found=""
  for candidate in "$found" /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    _axonflow_git_usable "$candidate" || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# _axonflow_identity_fallback_notice <reason> — one-line stderr diagnostic
# emitted when no identity resolves, so a developer or fleet admin can see WHY
# audit rows are about to attribute to the client-scoped id instead of a
# person (the silent version of this is exactly how a mis-provisioned fleet
# goes unnoticed — axonflow-enterprise#2832). Throttled to once per UTC day
# via a stamp file (house pattern: upgrade-prompt.sh) so it cannot spam every
# hook fire. When HOME is unset/unwritable (MDM / launchd / container
# contexts — exactly the fleets this targets) the stamp falls back to a
# per-uid tmp dir so the throttle still holds; only when NO stamp location is
# writable does the notice print every time (visibility beats silence at that
# point). The pre-tool and post-tool hooks racing on the very first fire can
# double-print once — benign, the stamp settles it from then on. Suppress
# entirely with AXONFLOW_IDENTITY_NOTICE=off.
_axonflow_identity_fallback_notice() {
  case "${AXONFLOW_IDENTITY_NOTICE:-}" in
    off|0|false|no) return 0 ;;
  esac
  local stamp_dir="${HOME:-}/.cache/axonflow"
  if ! mkdir -p "$stamp_dir" 2>/dev/null; then
    # Stamp content is a bare UTC date — nothing sensitive lands in tmp.
    stamp_dir="${TMPDIR:-/tmp}/axonflow-identity-${UID:-0}"
    mkdir -p "$stamp_dir" 2>/dev/null || stamp_dir=""
    # Shared-/tmp hygiene. The stamp path is predictable, so a local attacker
    # may pre-plant it. Reject two ways it can be abused, in order:
    #   1. A SYMLINK at the path — `[ -O ]` follows the link, so a symlink
    #      aimed at a directory WE own would otherwise pass the owner check
    #      and make the chmod/write below land on the link target (arbitrary
    #      chmod 0700 + a stray stamp file in a victim-chosen dir). `[ -h ]`
    #      does not dereference, so test it BEFORE the owner check and refuse
    #      any symlink outright.
    #   2. A real dir another local user owns — they could pre-stamp today's
    #      date to suppress the diagnostic. `[ -O ]` (dereference is moot now,
    #      symlinks are already gone) rejects a foreign-owned target.
    # Printing the notice every time beats writing to an unsafe location.
    if [ -n "$stamp_dir" ] && { [ -h "$stamp_dir" ] || [ ! -O "$stamp_dir" ]; }; then
      stamp_dir=""
    fi
  fi
  [ -n "$stamp_dir" ] && chmod 0700 "$stamp_dir" 2>/dev/null
  local stamp="${stamp_dir}/identity-fallback-notice-shown"
  local today=""
  today="$(date -u +%Y-%m-%d 2>/dev/null)" || today=""
  if [ -n "$stamp_dir" ] && [ -f "$stamp" ]; then
    local last=""
    last="$(awk 'NR==1 {print $1}' "$stamp" 2>/dev/null)" || last=""
    [ "$last" = "$today" ] && return 0
  fi
  if [ -n "$stamp_dir" ]; then
    printf '%s\n' "$today" >"$stamp" 2>/dev/null || true
  fi
  echo "[AxonFlow] No developer identity resolved (${1:-no identity source available}) — governed activity will be attributed to the client-scoped id, not a person, in the portal's User column. Fix: export AXONFLOW_USER_EMAIL=you@company.com (fleets: set it per developer via managed settings / MDM; silence this notice: AXONFLOW_IDENTITY_NOTICE=off). Docs: https://docs.getaxonflow.com/docs/enterprise/per-developer-identity" >&2
  return 0
}

# resolve_user_identity — side-effect only. Leaves AXONFLOW_USER_EMAIL_RESOLVED
# (possibly empty) and AXONFLOW_USER_IDENTITY_SOURCE ("env"|"git"|"none")
# exported when it returns. Always returns 0.
resolve_user_identity() {
  local email="" source="none" reason=""

  # 1. Explicit env var. Sanitize first — a set-but-blank value falls through
  #    to the git fallback rather than silently suppressing the header.
  if [ -n "${AXONFLOW_USER_EMAIL:-}" ]; then
    email="$(_sanitize_user_email "$AXONFLOW_USER_EMAIL")"
    if [ -n "$email" ]; then
      source="env"
    else
      reason="AXONFLOW_USER_EMAIL is set but blank after sanitization"
    fi
  else
    reason="AXONFLOW_USER_EMAIL is not set"
  fi

  # 2. Best-effort git fallback — NOT the Anthropic account email. Never fails
  #    the hook: any git error just yields an empty string.
  if [ -z "$email" ]; then
    local git_bin=""
    git_bin="$(_axonflow_find_git)" || git_bin=""
    if [ -z "$git_bin" ]; then
      reason="${reason}; git fallback unavailable (no usable git executable)"
    else
      # 2a. Merged read from the hook's cwd: repo-local wins inside a repo;
      #     outside a repo this still returns the global/system value, and in
      #     a dubious-ownership repo git itself skips the repo-local config
      #     and returns the global value. A GIT_DIR pointing at another valid
      #     repo is honored as-is (best-effort semantics — git's view of the
      #     identity is git's view).
      email="$("$git_bin" config user.email 2>/dev/null)" || email=""
      # 2b. Explicit global read — reaches the global identity even when the
      #     merged read dies (corrupt .git/config, deleted cwd — hence the
      #     cd /, which is contained in the command substitution's subshell).
      if [ -z "$email" ]; then
        email="$(cd / 2>/dev/null && "$git_bin" config --global user.email 2>/dev/null)" || email=""
      fi
      email="$(_sanitize_user_email "$email")"
      if [ -n "$email" ]; then
        source="git"
      else
        reason="${reason}; git config user.email could not be resolved (checked repo-local and global)"
      fi
    fi
  fi

  AXONFLOW_USER_EMAIL_RESOLVED="$email"
  AXONFLOW_USER_IDENTITY_SOURCE="$source"
  export AXONFLOW_USER_EMAIL_RESOLVED AXONFLOW_USER_IDENTITY_SOURCE

  if [ -z "$email" ]; then
    _axonflow_identity_fallback_notice "$reason"
  fi
  return 0
}
