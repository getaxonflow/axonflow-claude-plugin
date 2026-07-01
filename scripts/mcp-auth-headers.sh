#!/usr/bin/env bash
# Generate auth headers for the AxonFlow MCP server connection.
#
# NOTE (claude#56 follow-up): this script is NO LONGER referenced by
# `.mcp.json`'s `headersHelper`. Claude Code does not expand
# `${CLAUDE_PLUGIN_ROOT}` (or any env var) in the `headersHelper` field — only
# in command/args/env/url/headers — so pointing headersHelper at
# `${CLAUDE_PLUGIN_ROOT}/scripts/mcp-auth-headers.sh` resolved to a bad path,
# the helper never ran, and the MCP connection collapsed into OAuth discovery
# + the agent's plaintext "404 page not found". `.mcp.json` now inlines a
# self-contained, path-independent resolver that implements the SAME contract
# as this script. This file is retained as the readable reference impl and as
# the header-forwarding target for tests/host-cli-shim; keep the two in sync —
# tests/test-mcp-headers.sh pins the inline's behavior.
#
# Resolution order (ADR-048):
#   1. AXONFLOW_AUTH already exported by the user → use it (self-hosted /
#      enterprise / explicit credential).
#   2. No explicit AXONFLOW_AUTH and no AXONFLOW_ENDPOINT → run the
#      Community-SaaS bootstrap to register against try.getaxonflow.com
#      and load the resulting Basic-auth credential.
#   3. AXONFLOW_AUTH still empty after that (bootstrap couldn't run /
#      degraded) → emit empty headers (Community-mode self-hosted, no auth).

# When this script is invoked by Claude Code's headersHelper, AXONFLOW_MODE
# is not yet set; resolve it the same way pre-tool-check.sh does so the
# bootstrap helper makes the right call.
if [ -z "${AXONFLOW_MODE:-}" ]; then
  if [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
    AXONFLOW_MODE="community-saas"
  else
    AXONFLOW_MODE="self-hosted"
  fi
  export AXONFLOW_MODE
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/community-saas-bootstrap.sh"

# V1 paid Pro tier (axonflow-enterprise PR #1850): also resolve the paid-tier
# license token so MCP-server traffic carries X-License-Token alongside the
# Basic auth credential. Same env-then-file precedence as the hooks.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/license-token.sh"
resolve_license_token

# ADR-050 §4: every governed request to the agent carries X-Axonflow-Client
# so the agent can derive request scope (plugin) and validate it against the
# token's aud.scope via HasScope(). Sourced from .claude-plugin/plugin.json
# (no env override — the consumer doesn't get to spoof its own client identity).
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/client-header.sh"

# Per-developer identity (issue #2754): resolve AXONFLOW_USER_EMAIL (→ git
# fallback) so MCP-server traffic carries X-User-Email and the agent attributes
# the audit row to a real developer. Same env-then-git precedence as the hooks.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/user-identity.sh"
resolve_user_identity

AUTH="${AXONFLOW_AUTH:-}"
LICENSE_TOKEN="${AXONFLOW_LICENSE_TOKEN:-}"
CLIENT_HEADER="${AXONFLOW_CLIENT_HEADER}"
USER_EMAIL="${AXONFLOW_USER_EMAIL_RESOLVED:-}"

# Cross-deployment safety: drop X-License-Token when the cached token
# is a community-saas-issued (aud=community_saas_plugin) but the user
# has pointed AXONFLOW_ENDPOINT at a non-try.getaxonflow.com host.
# Otherwise the self-hosted v9 platform would receive a token signed
# with the community-saas Ed25519 key it can't verify and silently
# fail MCP auth with HTTP 401. See license-token.sh comment block.
if [ -n "$LICENSE_TOKEN" ] && ! license_token_endpoint_compatible; then
  LICENSE_TOKEN=""
fi

# Build the JSON header object via jq when available so values are json-escaped
# correctly. Each optional header is added only when its value is non-empty, so
# X-User-Email (issue #2754) is omitted cleanly when no identity resolves —
# never an empty header. X-Axonflow-Client always ships (ADR-050 §4). Without
# jq, fall back to a hand-quoted shape (X-License-Token needs careful escaping
# so it is dropped on this legacy path; per-call hooks still ship it).
if command -v jq &>/dev/null; then
  jq -nc \
    --arg auth "$AUTH" --arg lt "$LICENSE_TOKEN" --arg ch "$CLIENT_HEADER" --arg ue "$USER_EMAIL" \
    '{}
     | (if $auth != "" then . + {"Authorization": ("Basic " + $auth)} else . end)
     | (if $lt   != "" then . + {"X-License-Token": $lt} else . end)
     | (if $ue   != "" then . + {"X-User-Email": $ue} else . end)
     | . + {"X-Axonflow-Client": $ch}'
else
  ue_frag=""
  if [ -n "$USER_EMAIL" ]; then
    ue_frag=", \"X-User-Email\": \"$USER_EMAIL\""
  fi
  if [ -n "$AUTH" ]; then
    echo "{\"Authorization\": \"Basic $AUTH\"${ue_frag}, \"X-Axonflow-Client\": \"$CLIENT_HEADER\"}"
  else
    echo "{\"X-Axonflow-Client\": \"$CLIENT_HEADER\"${ue_frag}}"
  fi
fi
