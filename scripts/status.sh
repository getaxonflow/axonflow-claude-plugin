#!/usr/bin/env bash
# /axonflow-status slash-command implementation.
#
# Prints a one-screen status block for the AxonFlow Claude Code plugin so
# the user can:
#   1. find their `tenant_id` (needed to paste into the Stripe checkout
#      custom field when upgrading to AxonFlow Pro), and
#   2. confirm whether the plugin is currently in Free or Pro tier mode.
#
# Output is line-oriented to match login.sh / recover.sh:
#   OK  endpoint=<url>
#   OK  tenant_id=<id>            (or:  WARN tenant_id=<empty>  recovery hint)
#   OK  tier=Free|Pro
#   OK  license_token=set (AXON-...XXXX)   (Pro)   or   unset (Free)
#   OK  upgrade_url=<url>                  (Free only)
#
# Token redaction policy: NEVER print the full token. The status surface
# is exactly the moment a user is most likely to screen-share, paste into
# a support ticket, or pipe to a log file. Mirror the redaction approach
# from axonflow-codex-plugin#41 — "set (AXON-...<last4>)" if a token
# resolves, "unset" otherwise. Defensive **** padding for sub-4-char
# tokens (shouldn't happen — license_token_looks_valid in license-token.sh
# requires len >= 32 — but cheap insurance).
#
# Exit codes:
#   0 — status printed (always, even with an empty tenant_id; the recovery
#       hint is enough — no point failing the slash command on a missing
#       file the user would then have to debug).
#   1 — wholly unexpected internal failure (jq missing, etc.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/license-token.sh"

# Endpoint resolution — mirror pre-tool-check.sh / recover.sh exactly so
# the output reflects the same endpoint a governed call would hit.
if [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
  ENDPOINT="https://try.getaxonflow.com"
else
  ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
fi

# Registration file — honour AXONFLOW_CONFIG_DIR override (used by
# tests + air-gapped users who keep credentials elsewhere) before falling
# back to the canonical ~/.config/axonflow path.
CONFIG_DIR="${AXONFLOW_CONFIG_DIR:-${HOME}/.config/axonflow}"
REG_FILE="${CONFIG_DIR}/try-registration.json"

# Resolve tenant_id from the registration file. Don't enforce 0600 here:
# /axonflow-status is a read-only diagnostic. If the file is world-readable
# we still want to show the tenant_id (the user needs it for the Stripe
# checkout) but emit a stderr warning so they know to chmod it.
TENANT_ID=""
if [ -f "$REG_FILE" ]; then
  if command -v jq >/dev/null 2>&1; then
    TENANT_ID=$(jq -r '.tenant_id // empty' "$REG_FILE" 2>/dev/null || true)
  fi
  # Permission probe — same portability dance as license-token.sh.
  mode=$(stat -c %a "$REG_FILE" 2>/dev/null) || mode=""
  case "$mode" in
    ''|*[!0-9]*) mode=$(stat -f %Lp "$REG_FILE" 2>/dev/null) || mode="" ;;
  esac
  case "$mode" in
    ''|*[!0-9]*) mode="" ;;
  esac
  if [ -n "$mode" ] && [ "$mode" != "600" ] && [ "$mode" != "0600" ]; then
    echo "WARN $REG_FILE has unsafe permissions ($mode); chmod 600 to harden" >&2
  fi
fi

# Resolve license token via the canonical resolver (env wins, then file).
# Side-effect: AXONFLOW_LICENSE_TOKEN is set or empty after this call.
resolve_license_token

TIER="Free"
TOKEN_DISPLAY="unset"
if [ -n "${AXONFLOW_LICENSE_TOKEN:-}" ]; then
  TIER="Pro"
  TAIL4="****"
  if [ "${#AXONFLOW_LICENSE_TOKEN}" -ge 4 ]; then
    TAIL4="${AXONFLOW_LICENSE_TOKEN: -4}"
  fi
  TOKEN_DISPLAY="set (AXON-...${TAIL4})"
fi

UPGRADE_URL="${AXONFLOW_UPGRADE_URL:-https://getaxonflow.com/pro}"

# Emit the status block.
echo "OK  endpoint=${ENDPOINT}"
if [ -n "$TENANT_ID" ]; then
  echo "OK  tenant_id=${TENANT_ID}"
else
  echo "WARN tenant_id=<not found at ${REG_FILE}>"
  echo "    Run /axonflow-recover <email> if you've lost your registration,"
  echo "    or remove ${REG_FILE} and reload Claude Code to re-register against ${ENDPOINT}."
fi
echo "OK  tier=${TIER}"
echo "OK  license_token=${TOKEN_DISPLAY}"
if [ "$TIER" = "Free" ]; then
  echo "OK  upgrade_url=${UPGRADE_URL}"
  echo "    Paste your tenant_id above into the 'AxonFlow tenant ID' custom field at checkout."
fi

exit 0
