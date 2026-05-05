#!/usr/bin/env bash
# Resolve the X-Axonflow-Client header value from .claude-plugin/plugin.json.
#
# Sourced by every script that hits the AxonFlow agent so the agent can
# derive request scope (plugin) and validate it against the token's aud.scope
# via HasScope() — ADR-050 §4. Header value is "<client-id>/<version>", e.g.
# "claude-code-plugin/1.1.0".
#
# Idempotent: subsequent sourcing is a no-op once AXONFLOW_CLIENT_HEADER is
# already set. Plugin version comes from the canonical plugin.json — there
# is intentionally no env override (the consumer doesn't get to spoof its
# own client identity to the agent; this is the honest-99% header injection
# described in ADR-050 §4).

if [ -z "${AXONFLOW_CLIENT_HEADER:-}" ]; then
  _CLIENT_HEADER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _PLUGIN_VERSION=""
  if command -v jq &>/dev/null; then
    _PLUGIN_VERSION=$(jq -r '.version // empty' "${_CLIENT_HEADER_DIR}/../.claude-plugin/plugin.json" 2>/dev/null || true)
  fi
  if [ -z "$_PLUGIN_VERSION" ]; then
    _PLUGIN_VERSION="unknown"
  fi
  AXONFLOW_CLIENT_HEADER="claude-code-plugin/${_PLUGIN_VERSION}"
  export AXONFLOW_CLIENT_HEADER
  unset _CLIENT_HEADER_DIR _PLUGIN_VERSION
fi
