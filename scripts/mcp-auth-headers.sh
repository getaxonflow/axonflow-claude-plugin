#!/usr/bin/env bash
# Generate auth headers for the AxonFlow MCP server connection.
# Called by Claude Code's headersHelper at MCP session start.
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

AUTH="${AXONFLOW_AUTH:-}"
LICENSE_TOKEN="${AXONFLOW_LICENSE_TOKEN:-}"
CLIENT_HEADER="${AXONFLOW_CLIENT_HEADER}"

# Build the JSON header object via jq when available so token values are
# json-escaped correctly. Without jq, fall back to a bare Authorization +
# X-Axonflow-Client shape (X-License-Token would need careful escaping so
# we drop it on this legacy path; per-call hooks still ship it).
if command -v jq &>/dev/null; then
  if [ -n "$AUTH" ] && [ -n "$LICENSE_TOKEN" ]; then
    jq -nc --arg auth "$AUTH" --arg lt "$LICENSE_TOKEN" --arg ch "$CLIENT_HEADER" \
      '{"Authorization": ("Basic " + $auth), "X-License-Token": $lt, "X-Axonflow-Client": $ch}'
  elif [ -n "$AUTH" ]; then
    jq -nc --arg auth "$AUTH" --arg ch "$CLIENT_HEADER" \
      '{"Authorization": ("Basic " + $auth), "X-Axonflow-Client": $ch}'
  elif [ -n "$LICENSE_TOKEN" ]; then
    jq -nc --arg lt "$LICENSE_TOKEN" --arg ch "$CLIENT_HEADER" \
      '{"X-License-Token": $lt, "X-Axonflow-Client": $ch}'
  else
    jq -nc --arg ch "$CLIENT_HEADER" '{"X-Axonflow-Client": $ch}'
  fi
else
  if [ -n "$AUTH" ]; then
    echo "{\"Authorization\": \"Basic $AUTH\", \"X-Axonflow-Client\": \"$CLIENT_HEADER\"}"
  else
    echo "{\"X-Axonflow-Client\": \"$CLIENT_HEADER\"}"
  fi
fi
