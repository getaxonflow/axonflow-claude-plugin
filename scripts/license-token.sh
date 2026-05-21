#!/usr/bin/env bash
# License-token resolution + persistence helpers for the V1 paid Pro tier
# (axonflow-enterprise PR #1850).
#
# The plugin sends the user's paid-tier license token (an `AXON-`-prefixed
# string issued by the Stripe webhook handler) as the `X-License-Token`
# HTTP header on every governed agent request. The agent's
# PluginClaimMiddleware validates the token and sets a Pro-tier context
# downstream handlers branch on (retention, quota, etc.).
#
# This file is sourced by the hooks (`pre-tool-check.sh`) and the headers
# helper (`mcp-auth-headers.sh`) — never invoked. After sourcing, the
# `AXONFLOW_LICENSE_TOKEN` variable is exported with the resolved token
# (empty if none found / token expired).
#
# Resolution order (canonical, must not change without a CHANGELOG entry):
#
#   1. AXONFLOW_LICENSE_TOKEN env var (set by the user's shell or
#      .envrc-style tool) — wins outright.
#   2. ~/.config/axonflow/license-token.json — written by `/axonflow-login
#      --token <token>` slash command.
#
# File on disk:
#   {"token": "AXON-...", "saved_at": "2026-05-04T18:22:00Z",
#    "endpoint": "<optional override>"}
#
# Mode is 0600 inside a 0700 directory — same permissions discipline as
# try-registration.json. A file with non-0600 permissions is REJECTED with
# a stderr warning rather than loaded silently.
#
# Never exits non-zero. Never blocks the calling hook.

# Config dir and file paths.
LICENSE_TOKEN_CONFIG_DIR="${HOME}/.config/axonflow"
LICENSE_TOKEN_FILE="${LICENSE_TOKEN_CONFIG_DIR}/license-token.json"

# Token shape sanity check. AXON-prefixed tokens are issued by the platform
# (license.IssuePluginClaimToken) and are at least 32 chars long. Reject
# obviously-malformed strings before we send them on the wire — the platform
# would reject them with 401 anyway, but failing locally is faster and
# produces a clearer message.
license_token_looks_valid() {
  local tok="$1"
  [ -n "$tok" ] || return 1
  case "$tok" in
    AXON-*) ;;
    *) return 1 ;;
  esac
  # Minimum overall length (prefix + signature material). Real tokens are
  # ~250 chars; anything under 32 is definitely junk.
  if [ ${#tok} -lt 32 ]; then
    return 1
  fi
  return 0
}

# load_license_token_from_file — read the on-disk token, validate file
# permissions, and export AXONFLOW_LICENSE_TOKEN if present and shaped right.
# Refuses to read a file with non-0600 permissions (same security posture as
# the try-registration.json loader).
load_license_token_from_file() {
  local file="$1"
  [ -f "$file" ] || return 1

  # Same portability pattern used in community-saas-bootstrap.sh: try GNU
  # stat first (CI is Linux), fall back to BSD (macOS dev machines), and
  # validate the result is numeric in both branches.
  local mode
  mode=$(stat -c %a "$file" 2>/dev/null) || mode=""
  case "$mode" in
    ''|*[!0-9]*) mode=$(stat -f %Lp "$file" 2>/dev/null) || mode="" ;;
  esac
  case "$mode" in
    ''|*[!0-9]*) mode="" ;;
  esac
  if [ "$mode" != "600" ] && [ "$mode" != "0600" ]; then
    echo "[AxonFlow] $file has unsafe permissions ($mode); refusing to use. Re-save with /axonflow-login or chmod 600 '$file'" >&2
    return 1
  fi

  command -v jq &>/dev/null || return 1
  local tok
  tok=$(jq -r '.token // empty' "$file" 2>/dev/null)
  if ! license_token_looks_valid "$tok"; then
    return 1
  fi
  AXONFLOW_LICENSE_TOKEN="$tok"
  export AXONFLOW_LICENSE_TOKEN
  return 0
}

# Resolve the token: env wins, file is the fallback. Side-effect-only:
# leaves AXONFLOW_LICENSE_TOKEN exported (or unset) when it returns.
#
# The on-disk cache is loaded unconditionally. The downstream
# safety check (skip-when-aud-and-endpoint-mismatch) lives in
# license_token_endpoint_compatible — it inspects the cached token's
# aud claim and the current AXONFLOW_ENDPOINT to decide whether to
# emit X-License-Token on the wire. That keeps resolve_license_token
# focused on "is there a token at all?" and gives the headers helper
# (and tests of it) a clean signal it can override per-request.
#
# Earlier iterations of the fix:
#  - commit 0f6ade6 — skipped cache when AXONFLOW_AUTH was set. Too
#    broad: community-saas-bootstrap.sh exports AXONFLOW_AUTH on every
#    community-saas first-run, so a Pro user on community-saas lost
#    their X-License-Token header.
#  - commit 79be132 — skipped cache when AXONFLOW_ENDPOINT was set to
#    a non-try.getaxonflow.com host. Broke the host-cli-shim's
#    Pro/file scenario which legitimately uses a localhost shim
#    endpoint AND expects the file-token to load.
#
# Current fix: cache always loads (so tests + opt-in operators work);
# aud↔endpoint mismatch is detected in license_token_endpoint_compatible
# and the headers helper drops X-License-Token when incompatible.
#
# Caught during v9 preflight 2026-05-21.
resolve_license_token() {
  if [ -n "${AXONFLOW_LICENSE_TOKEN:-}" ]; then
    if license_token_looks_valid "$AXONFLOW_LICENSE_TOKEN"; then
      export AXONFLOW_LICENSE_TOKEN
      return 0
    fi
    # Env var set but malformed — log and unset rather than send junk.
    echo "[AxonFlow] AXONFLOW_LICENSE_TOKEN is set but does not look like a valid AXON- token; ignoring" >&2
    unset AXONFLOW_LICENSE_TOKEN
  fi
  load_license_token_from_file "$LICENSE_TOKEN_FILE" >/dev/null 2>&1 || true
}

# license_token_endpoint_compatible — returns 0 (true) if the cached
# AXONFLOW_LICENSE_TOKEN's aud claim is consistent with the current
# AXONFLOW_ENDPOINT, 1 (false) otherwise.
#
# The aud values minted by the platform (ADR-050):
#   - axonflow.self_hosted.{plugin,sdk,full} → self-hosted licenses,
#     valid against any endpoint
#   - community_saas_plugin → Plugin Pro v1 token, ONLY valid when
#     sent to try.getaxonflow.com (community-saas signing key)
#
# So the only incompatible case is: aud=community_saas_plugin sent to
# a non-try.getaxonflow.com endpoint. That's the stale-token-leak
# we're protecting against.
#
# Token not set, malformed, or aud missing: treat as compatible
# (no-op skip). The downstream platform will reject anything invalid.
license_token_endpoint_compatible() {
  local tok="${AXONFLOW_LICENSE_TOKEN:-}"
  [ -z "$tok" ] && return 0

  # Endpoint not set, or pointing at community-saas SaaS → compatible.
  local endpoint="${AXONFLOW_ENDPOINT:-}"
  if [ -z "$endpoint" ] || [[ "$endpoint" == *try.getaxonflow.com* ]]; then
    return 0
  fi

  # Endpoint is self-hosted. Check the token's aud — only fail if
  # it's community_saas_plugin. Other auds (self_hosted.*) are fine.
  local payload_b64="${tok#AXON-}"
  payload_b64="${payload_b64%%.*}"
  # Decode base64url (no padding) → JSON
  local aud
  aud=$(printf '%s' "$payload_b64" | python3 -c "
import sys, base64, json
b = sys.stdin.read()
b += '=' * (-len(b) % 4)
try:
  print(json.loads(base64.urlsafe_b64decode(b)).get('aud', ''))
except Exception:
  pass
" 2>/dev/null)
  case "$aud" in
    community_saas_plugin)
      return 1  # incompatible
      ;;
    *)
      return 0
      ;;
  esac
}

# Helper to atomically write the on-disk token file with 0600 perms.
# Used by the /axonflow-login slash command's runtime invocation. Returns
# 0 on success, 1 on any failure (and logs the reason on stderr).
save_license_token_to_file() {
  local tok="$1"
  if ! license_token_looks_valid "$tok"; then
    echo "[AxonFlow] save_license_token_to_file: token does not look valid" >&2
    return 1
  fi
  command -v jq &>/dev/null || {
    echo "[AxonFlow] save_license_token_to_file: jq not on PATH" >&2
    return 1
  }
  mkdir -p "$LICENSE_TOKEN_CONFIG_DIR" 2>/dev/null && chmod 0700 "$LICENSE_TOKEN_CONFIG_DIR" 2>/dev/null
  local tmp="${LICENSE_TOKEN_FILE}.tmp.$$"
  local saved_at
  saved_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if (umask 077 && jq -n --arg t "$tok" --arg s "$saved_at" '{token: $t, saved_at: $s}' > "$tmp" 2>/dev/null) \
     && mv -f "$tmp" "$LICENSE_TOKEN_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  echo "[AxonFlow] save_license_token_to_file: failed to write $LICENSE_TOKEN_FILE" >&2
  return 1
}
