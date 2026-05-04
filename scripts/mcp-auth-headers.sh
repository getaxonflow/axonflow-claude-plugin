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

AUTH="${AXONFLOW_AUTH:-}"
LICENSE_TOKEN="${AXONFLOW_LICENSE_TOKEN:-}"

# Build the JSON header object via jq when available so token values are
# json-escaped correctly. Without jq, fall back to the legacy bare-Authorization
# shape (X-License-Token still ships on per-call hooks, which run independently).
if command -v jq &>/dev/null; then
  if [ -n "$AUTH" ] && [ -n "$LICENSE_TOKEN" ]; then
    jq -nc --arg auth "$AUTH" --arg lt "$LICENSE_TOKEN" \
      '{"Authorization": ("Basic " + $auth), "X-License-Token": $lt}'
  elif [ -n "$AUTH" ]; then
    jq -nc --arg auth "$AUTH" '{"Authorization": ("Basic " + $auth)}'
  elif [ -n "$LICENSE_TOKEN" ]; then
    jq -nc --arg lt "$LICENSE_TOKEN" '{"X-License-Token": $lt}'
  else
    echo "{}"
  fi
else
  if [ -n "$AUTH" ]; then
    echo "{\"Authorization\": \"Basic $AUTH\"}"
  else
    echo "{}"
  fi
fi
