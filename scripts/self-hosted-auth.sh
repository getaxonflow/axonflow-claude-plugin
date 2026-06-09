#!/usr/bin/env bash
# Self-hosted / Enterprise credential resolution + persistence helpers.
#
# Background (axonflow-claude-plugin#94)
# -------------------------------------
# The plugin authenticates to a self-hosted / Enterprise agent with HTTP Basic
# auth: base64("<org_id>:<license_key>") in the Authorization header. Until now
# the ONLY source for that credential was the AXONFLOW_AUTH env var — unlike
# Community-SaaS (durably cached in ~/.config/axonflow/try-registration.json)
# and Pro (~/.config/axonflow/license-token.json). That single-source design
# had two failure modes a design partner hit on a real Enterprise install:
#
#   1. When AXONFLOW_AUTH did not reach a subprocess (env divergence between
#      the per-call hooks and the MCP `headersHelper`), there was no fallback,
#      so MCP auth silently failed with HTTP 401.
#   2. Worse, the inline `headersHelper` fell back to the Community-SaaS
#      `try-registration.json` regardless of endpoint — sending a `cs_<uuid>`
#      credential to the Enterprise agent, which rejected it with
#      "invalid license key prefix (expected AXON-)" → 401 → `/mcp` "failed".
#
# This file gives the HOOKS the same resolution the (now mode-gated) inline
# `headersHelper` performs, so the two planes agree:
#
#   * resolve_self_hosted_auth — when AXONFLOW_MODE != community-saas and
#     AXONFLOW_AUTH is empty, load the base64 credential from
#     ~/.config/axonflow/self-hosted-auth.json (0600-checked) and export it.
#   * axonflow_normalize_basic_auth — coerce a raw "<org>:<key>" value to the
#     base64 the agent expects (a raw value is sent verbatim as "Basic <raw>"
#     and 401s; base64 never contains ':' so the detection is unambiguous).
#   * save_self_hosted_auth_to_file — atomic 0600 writer used by the
#     /axonflow-login --self-hosted slash command.
#
# Sourced (never invoked) by pre-tool-check.sh / post-tool-audit.sh / login.sh.
# Never exits non-zero; never blocks the calling hook.

# Config dir: AXONFLOW_CONFIG_DIR override (used by runtime-e2e to sandbox the
# credential files without touching ~/.config/axonflow), else the default.
# Mirrors the path the inline .mcp.json headersHelper reads.
SELF_HOSTED_AUTH_CONFIG_DIR="${AXONFLOW_CONFIG_DIR:-${HOME}/.config/axonflow}"
SELF_HOSTED_AUTH_FILE="${SELF_HOSTED_AUTH_CONFIG_DIR}/self-hosted-auth.json"

# axonflow_normalize_basic_auth <value> → prints the base64 the agent expects.
# A raw "<org>:<key>" (contains ':') is base64-encoded; an already-base64 value
# (the base64 alphabet has no ':') is passed through unchanged. Empty in → empty
# out. Pure stdout, no side effects.
axonflow_normalize_basic_auth() {
  local v="$1"
  [ -n "$v" ] || { printf ''; return 0; }
  case "$v" in
    *:*) printf '%s' "$v" | base64 | tr -d '\n' ;;
    *)   printf '%s' "$v" ;;
  esac
}

# load_self_hosted_auth_from_file <file> — read the on-disk base64 credential,
# enforce 0600 perms (same posture as the try-registration.json / license-token
# loaders), and export AXONFLOW_AUTH. Returns 1 (without exporting) on any
# problem so the caller can fall through cleanly.
load_self_hosted_auth_from_file() {
  local file="$1"
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # Portability: GNU `stat -c` first (CI is Linux), then BSD `stat -f` (macOS),
  # validating numeric output in both branches — matches community-saas-bootstrap.
  local mode
  mode=$(stat -c %a "$file" 2>/dev/null) || mode=""
  case "$mode" in
    ''|*[!0-9]*) mode=$(stat -f %Lp "$file" 2>/dev/null) || mode="" ;;
  esac
  case "$mode" in
    ''|*[!0-9]*) mode="" ;;
  esac
  if [ "$mode" != "600" ] && [ "$mode" != "0600" ]; then
    echo "[AxonFlow] $file has unsafe permissions ($mode); refusing to use. Re-save with /axonflow-login --self-hosted or chmod 600 '$file'" >&2
    return 1
  fi

  local val
  val=$(jq -r '.auth // empty' "$file" 2>/dev/null)
  [ -n "$val" ] || return 1
  AXONFLOW_AUTH="$(axonflow_normalize_basic_auth "$val")"
  export AXONFLOW_AUTH
  return 0
}

# resolve_self_hosted_auth — side-effect-only credential resolution for the
# hooks. Honors the same precedence the inline headersHelper uses:
#   1. AXONFLOW_AUTH already set (env wins) → only normalize a raw value.
#   2. Self-hosted mode + empty → load self-hosted-auth.json.
# Community-SaaS mode is left entirely to community-saas-bootstrap.sh; this is a
# no-op there so the two credential planes never cross.
resolve_self_hosted_auth() {
  if [ -n "${AXONFLOW_AUTH:-}" ]; then
    AXONFLOW_AUTH="$(axonflow_normalize_basic_auth "$AXONFLOW_AUTH")"
    export AXONFLOW_AUTH
    return 0
  fi
  # Only the self-hosted plane uses this file. In community-saas mode the
  # registration bootstrap owns the credential.
  if [ "${AXONFLOW_MODE:-}" = "community-saas" ]; then
    return 0
  fi
  load_self_hosted_auth_from_file "$SELF_HOSTED_AUTH_FILE" >/dev/null 2>&1 || true
}

# save_self_hosted_auth_to_file <org_id> <license_key> — atomically persist the
# self-hosted credential as base64("<org>:<key>") with 0600 perms inside a 0700
# directory. Returns 0 on success, 1 (with a stderr reason) on failure.
save_self_hosted_auth_to_file() {
  local org="$1" key="$2"
  if [ -z "$org" ] || [ -z "$key" ]; then
    echo "[AxonFlow] save_self_hosted_auth_to_file: org_id and license_key are both required" >&2
    return 1
  fi
  case "$org" in *:*) echo "[AxonFlow] save_self_hosted_auth_to_file: org_id must not contain ':'" >&2; return 1 ;; esac
  command -v jq >/dev/null 2>&1 || { echo "[AxonFlow] save_self_hosted_auth_to_file: jq not on PATH" >&2; return 1; }

  mkdir -p "$SELF_HOSTED_AUTH_CONFIG_DIR" 2>/dev/null && chmod 0700 "$SELF_HOSTED_AUTH_CONFIG_DIR" 2>/dev/null
  local b64 saved_at tmp
  b64=$(printf '%s:%s' "$org" "$key" | base64 | tr -d '\n')
  saved_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp="${SELF_HOSTED_AUTH_FILE}.tmp.$$"
  if (umask 077 && jq -n --arg o "$org" --arg k "$key" --arg a "$b64" --arg s "$saved_at" \
        '{org_id: $o, license_key: $k, auth: $a, saved_at: $s}' > "$tmp" 2>/dev/null) \
     && mv -f "$tmp" "$SELF_HOSTED_AUTH_FILE" 2>/dev/null; then
    chmod 0600 "$SELF_HOSTED_AUTH_FILE" 2>/dev/null
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  echo "[AxonFlow] save_self_hosted_auth_to_file: failed to write $SELF_HOSTED_AUTH_FILE" >&2
  return 1
}
