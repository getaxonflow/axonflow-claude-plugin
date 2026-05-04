#!/usr/bin/env bash
# /axonflow-login slash-command implementation.
#
# Persists a paid AxonFlow Pro license token (AXON-...) to
# ~/.config/axonflow/license-token.json so subsequent governed agent
# requests carry it as the X-License-Token header.
#
# Invoked by the user's agent via a Bash tool call dispatched from the
# /axonflow-login slash command. Token is passed as $1.
#
# Output is line-oriented for easy parsing:
#   OK    token=AXON-XXXX path=<file>
#   ERR   <message>
# The slash command renders this output back to the user.
#
# Exit codes:
#   0 — token saved (line "OK ...")
#   1 — invalid argument or write failure (line "ERR ...")

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/license-token.sh"

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  echo "ERR  Missing token argument. Usage: /axonflow-login <AXON-...>" >&2
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
