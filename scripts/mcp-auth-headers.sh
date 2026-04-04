#!/usr/bin/env bash
# Generate auth headers for the AxonFlow MCP server connection.
# Called by Claude Code's headersHelper at MCP session start.
#
# Community mode (AXONFLOW_AUTH empty): no auth header needed
# Enterprise mode (AXONFLOW_AUTH set):  Basic auth with base64-encoded clientId:clientSecret
#
# AXONFLOW_AUTH must be base64-encoded "clientId:clientSecret"
# Example: echo -n "my-client:my-secret" | base64

AUTH="${AXONFLOW_AUTH:-}"

if [ -n "$AUTH" ]; then
  echo "{\"Authorization\": \"Basic $AUTH\"}"
else
  # Community mode — no auth required, send empty headers
  echo "{}"
fi
