#!/usr/bin/env bash
# Per-user authorization token resolution for governed AxonFlow requests —
# axonflow-enterprise#2935 (epic #2919: per-user identity + role on the
# fleet/MCP-server plane).
#
# The platform's fleet plane authenticates the TENANT with the shared Basic
# credential; a per-user token yields a VALIDATED, non-forgeable
# {identity, role} for the developer behind the session
# (platform/agent/mcp_server_handler.go authenticateMCPServerRequest →
# extractPerUserToken, which reads the `X-User-Token` header). The token is
# minted by an org admin via the platform mint API
# (POST /api/v1/admin/organizations/{org_id}/user-tokens, enterprise#2930)
# and delivered to each developer via managed settings / MDM — the same
# distribution channel as AXONFLOW_USER_EMAIL.
#
# This file is sourced by the hooks (pre-tool-check.sh, post-tool-audit.sh)
# and the headers reference impl (mcp-auth-headers.sh) — never invoked. After
# sourcing and calling resolve_user_token, AXONFLOW_USER_TOKEN is exported
# with the resolved token (unset/empty if none is configured). The callers
# send it as `X-User-Token` ONLY when non-empty — an unconfigured developer's
# requests are byte-identical to today's (no empty header), and the platform
# keeps its existing least-privilege attribution path.
#
# Resolution order (canonical, must not change without a CHANGELOG entry):
#
#   1. AXONFLOW_USER_TOKEN env var (managed settings / MDM env block, same
#      mechanism as AXONFLOW_USER_EMAIL per #2762) — wins outright.
#   2. ~/.config/axonflow/user-token.json — {"token": "<minted token>"},
#      written by the fleet's provisioning tooling.
#
# Mode is 0600 inside a 0700 directory — same permissions discipline as
# license-token.json. A file with non-0600 permissions is REJECTED with a
# stderr warning rather than loaded silently.
#
# The token VALUE is a credential: it is never logged, never echoed, and
# never written to stdout by this helper (stdout belongs to the calling
# hook's protocol).
#
# Never exits non-zero. Never blocks the calling hook.

# Config dir and file paths.
USER_TOKEN_CONFIG_DIR="${HOME}/.config/axonflow"
USER_TOKEN_FILE="${USER_TOKEN_CONFIG_DIR}/user-token.json"

# user_token_looks_valid — sanity-gate a candidate token before it goes on
# the wire. Minted per-user tokens (HS256 Path A and OIDC Path B) are compact
# JWTs: base64url segments joined by dots — no whitespace, no control bytes,
# no quotes, no backslashes. A candidate containing any of those is junk
# (mis-pasted, truncated multi-line, or corrupted), and sending it would be
# WORSE than sending nothing: the platform fails closed on a presented-but-
# invalid token (an access attempt, not a legacy caller), turning every
# governed call into an auth denial. Rejecting locally keeps the developer on
# the least-privilege path with a clear stderr diagnostic instead.
#
# Deliberately does NOT pin the JWT structure (segment count, prefix): the
# platform owns token-format evolution; this guard only rejects values that
# can never be a wire-safe credential. The check also guarantees the value is
# safe to interpolate into the .mcp.json headersHelper's printf-assembled
# JSON (no quote/backslash escaping needed) and into an HTTP header (no
# CR/LF header-splitting bytes).
user_token_looks_valid() {
  local tok="$1"
  [ -n "$tok" ] || return 1
  local cleaned
  cleaned=$(printf '%s' "$tok" | tr -d '[:space:][:cntrl:]"\\')
  [ "$cleaned" = "$tok" ] || return 1
  return 0
}

# load_user_token_from_file — read the on-disk token, validate file
# permissions, and export AXONFLOW_USER_TOKEN if present and shaped right.
# Refuses to read a file with non-0600 permissions (same security posture as
# the license-token.json loader).
load_user_token_from_file() {
  local file="$1"
  [ -f "$file" ] || return 1

  # Same portability pattern as license-token.sh: try GNU stat first (CI is
  # Linux), fall back to BSD (macOS dev machines), and validate the result is
  # numeric in both branches.
  local mode
  mode=$(stat -c %a "$file" 2>/dev/null) || mode=""
  case "$mode" in
    ''|*[!0-9]*) mode=$(stat -f %Lp "$file" 2>/dev/null) || mode="" ;;
  esac
  case "$mode" in
    ''|*[!0-9]*) mode="" ;;
  esac
  if [ "$mode" != "600" ] && [ "$mode" != "0600" ]; then
    echo "[AxonFlow] $file has unsafe permissions ($mode); refusing to use. chmod 600 '$file' to restore per-user authorization" >&2
    return 1
  fi

  command -v jq &>/dev/null || return 1
  local tok
  tok=$(jq -r '.token // empty' "$file" 2>/dev/null)
  if ! user_token_looks_valid "$tok"; then
    # Never print the value — it may be a credential with a typo in it.
    if [ -n "$tok" ]; then
      echo "[AxonFlow] $file contains a malformed per-user token (whitespace/control/quote bytes); ignoring. Re-provision it from your admin's mint output" >&2
    fi
    return 1
  fi
  AXONFLOW_USER_TOKEN="$tok"
  export AXONFLOW_USER_TOKEN
  return 0
}

# resolve_user_token — env wins, file is the fallback. Side-effect-only:
# leaves AXONFLOW_USER_TOKEN exported with a wire-safe token, or unset when
# none is configured (callers then omit X-User-Token entirely). Always
# returns 0.
resolve_user_token() {
  if [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then
    if user_token_looks_valid "$AXONFLOW_USER_TOKEN"; then
      export AXONFLOW_USER_TOKEN
      return 0
    fi
    # Env var set but malformed — warn (never the value) and unset rather
    # than send junk the platform would fail closed on.
    echo "[AxonFlow] AXONFLOW_USER_TOKEN is set but contains whitespace/control/quote bytes; ignoring. Re-provision it from your admin's mint output" >&2
    unset AXONFLOW_USER_TOKEN
  fi
  load_user_token_from_file "$USER_TOKEN_FILE" || true
  return 0
}
