#!/usr/bin/env bash
# /axonflow-login slash-command implementation.
#
# Two modes:
#   login.sh <AXON-token>
#     Persists a paid AxonFlow Pro license token to
#     ~/.config/axonflow/license-token.json (X-License-Token on every request).
#   login.sh --self-hosted <org_id> <license_key>
#     Persists a self-hosted / Enterprise Basic-auth credential to
#     ~/.config/axonflow/self-hosted-auth.json so the MCP headersHelper AND the
#     hooks can authenticate even when AXONFLOW_AUTH is not exported into every
#     subprocess (axonflow-claude-plugin#94). Mirrors the durable on-disk
#     credential Community-SaaS already has via try-registration.json.
#
# Invoked by the user's agent via a Bash tool call dispatched from a slash
# command. Output is line-oriented for easy parsing:
#   OK    <details>
#   ERR   <message>
# The slash command renders this output back to the user.
#
# Exit codes:
#   0 — saved (line "OK ...")
#   1 — invalid argument or write failure (line "ERR ...")

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/license-token.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/self-hosted-auth.sh"

# --self-hosted <org_id> <license_key> — Enterprise Basic-auth credential.
if [ "${1:-}" = "--self-hosted" ]; then
  ORG_ID="${2:-}"
  LICENSE_KEY="${3:-}"
  if [ -z "$ORG_ID" ] || [ -z "$LICENSE_KEY" ]; then
    echo "ERR  Usage: /axonflow-login --self-hosted <org_id> <license_key>" >&2
    exit 1
  fi
  if save_self_hosted_auth_to_file "$ORG_ID" "$LICENSE_KEY"; then
    echo "OK  self_hosted org_id=${ORG_ID} key_length=${#LICENSE_KEY} path=${SELF_HOSTED_AUTH_FILE}"
    echo "    Enterprise Basic-auth credential saved. Precedence: AXONFLOW_AUTH env var still wins; this file is the fallback."
    echo "    Restart any open Claude Code session for the credential to take effect on the MCP server connection (headersHelper only fires at session start)."
    exit 0
  else
    echo "ERR  Failed to write ${SELF_HOSTED_AUTH_FILE}. Check perms on ~/.config/axonflow." >&2
    exit 1
  fi
fi

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  echo "ERR  Missing token argument. Usage: /axonflow-login <AXON-...>  (or: /axonflow-login --self-hosted <org_id> <license_key>)" >&2
  exit 1
fi

TOKEN="$1"

if ! license_token_looks_valid "$TOKEN"; then
  echo "ERR  Token does not look like a valid AXON- license token (must start with AXON- and be at least 32 chars). Paste the token from your AxonFlow welcome email." >&2
  exit 1
fi

if save_license_token_to_file "$TOKEN"; then
  PREFIX="${TOKEN:0:12}…"
  echo "OK  token_prefix=${PREFIX} length=${#TOKEN} path=${LICENSE_TOKEN_FILE}"
  echo "    Pro tier active on the next governed tool call."
  echo "    Restart any open Claude Code session for the new token to take effect on the MCP server connection (headersHelper only fires at session start)."
  exit 0
else
  echo "ERR  Failed to write ${LICENSE_TOKEN_FILE}. Check perms on ~/.config/axonflow." >&2
  exit 1
fi
