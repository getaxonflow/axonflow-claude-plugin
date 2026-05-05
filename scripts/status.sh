#!/usr/bin/env bash
# /axonflow-status slash-command implementation.
#
# Prints a one-screen status block for the AxonFlow Claude Code plugin so
# the user can:
#   1. find their `tenant_id` (needed to paste into the Stripe checkout
#      custom field when upgrading to AxonFlow Pro),
#   2. confirm whether the plugin is currently in Free or Pro tier mode, and
#   3. see when the Pro license expires (so they can renew before it lapses
#      rather than discovering it at the next governed tool call).
#
# Output is line-oriented to match login.sh / recover.sh:
#   OK  endpoint=<url>
#   OK  tenant_id=<id>            (or:  WARN tenant_id=<empty>  recovery hint)
#   OK  tier=Pro (expires 2026-08-03, 90 days remaining)        (Pro active)
#   OK  tier=Free (Pro expired 2026-02-04 — visit <url> to renew) (Pro lapsed)
#   OK  tier=Free (no Pro license configured)                    (Free)
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
# JWT exp parsing: the AXON- prefix wraps a standard JWT (header.payload.
# signature); we extract `exp` from the payload to display the expiry date.
# Signature is NOT validated here — that is the platform's job. We only
# parse to display; if parsing fails we fall back to a "could not parse"
# variant rather than blocking the status surface.
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
# Note: resolve_license_token does NOT check `exp` — an expired-but-shaped
# token still ends up in AXONFLOW_LICENSE_TOKEN. The exp branch below is
# what flips Pro to "Free (Pro expired …)" when that happens.
resolve_license_token

# extract_jwt_exp <token>  →  prints unix-epoch integer to stdout, exits 0
# on success, non-zero on any parse failure. Pure stdout/stderr; never
# raises. The caller decides how to render a parse failure.
#
# AxonFlow license tokens are formatted `AXON-<JWT>` where <JWT> is a
# standard `header.payload.signature` triple. We base64url-decode the
# middle segment, then look for `"exp":<digits>`. Signature is NEVER
# validated here — display only.
extract_jwt_exp() {
  local tok="$1"
  [ -n "$tok" ] || return 1
  # Strip AXON- prefix; the rest is the JWT.
  local jwt="${tok#AXON-}"
  # Pull the payload (middle segment).
  local payload
  payload=$(printf '%s' "$jwt" | cut -d. -f2)
  [ -n "$payload" ] || return 1
  # base64url → base64 (replace -_ with +/) and pad to a multiple of 4.
  payload=$(printf '%s' "$payload" | tr '_-' '/+')
  local pad=$(( 4 - ${#payload} % 4 ))
  if [ "$pad" -ne 4 ]; then
    payload="${payload}$(printf '=%.0s' $(seq 1 "$pad"))"
  fi
  # base64 -d differs across platforms: Linux GNU coreutils uses `-d`,
  # BSD/macOS uses `-D`. Try GNU first, fall back to BSD.
  local decoded
  decoded=$(printf '%s' "$payload" | base64 -d 2>/dev/null) \
    || decoded=$(printf '%s' "$payload" | base64 -D 2>/dev/null) \
    || return 1
  [ -n "$decoded" ] || return 1
  # Extract the exp integer. We deliberately do NOT use jq here — the JWT
  # payload has untrusted contents and we want zero-dependency parsing
  # for status (it runs in minimal shells too). The grep pattern is
  # locked to a numeric value to avoid pulling in stringy fields named
  # "expires" / "exp_at" / etc.
  local exp
  exp=$(printf '%s' "$decoded" | grep -oE '"exp"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')
  [ -n "$exp" ] || return 1
  printf '%s' "$exp"
}

# format_unix_to_date <unix-epoch>  →  prints YYYY-MM-DD (UTC) to stdout.
# Falls back to the empty string + non-zero exit on platform mismatch.
format_unix_to_date() {
  local epoch="$1"
  [ -n "$epoch" ] || return 1
  # GNU date (Linux / CI): -d @<epoch>
  local out
  out=$(date -u -d "@${epoch}" +%Y-%m-%d 2>/dev/null) \
    || out=$(date -u -r "${epoch}" +%Y-%m-%d 2>/dev/null) \
    || return 1
  printf '%s' "$out"
}

# Compute the tier line. Three branches:
#   1. No token resolved          → "Free (no Pro license configured)"
#   2. Token resolved + exp parsed:
#       2a. exp in future         → "Pro (expires YYYY-MM-DD, N days remaining)"
#       2b. exp in past           → "Free (Pro expired YYYY-MM-DD — visit <url> to renew)"
#   3. Token resolved + exp NOT parseable
#                                 → "Pro (expires UNKNOWN — could not parse token)"
#
# The PRO_EXPIRED_FLAG is set when branch 2b fires; downstream rendering
# uses it to suppress the redundant "license_token=set" line (the token
# is on disk but inert) and to surface the renew CTA.
TIER_LINE=""
PRO_EXPIRED_FLAG=0
TIER_KIND="free"  # free | pro | pro-expired (for license_token line below)
TOKEN_DISPLAY="unset"
UPGRADE_URL="${AXONFLOW_UPGRADE_URL:-https://getaxonflow.com/pro}"

if [ -n "${AXONFLOW_LICENSE_TOKEN:-}" ]; then
  # Always compute redacted preview first — it shows up in license_token=
  # regardless of whether exp parses or has lapsed.
  TAIL4="****"
  if [ "${#AXONFLOW_LICENSE_TOKEN}" -ge 4 ]; then
    TAIL4="${AXONFLOW_LICENSE_TOKEN: -4}"
  fi
  TOKEN_DISPLAY="set (AXON-...${TAIL4})"

  EXP_EPOCH=$(extract_jwt_exp "$AXONFLOW_LICENSE_TOKEN" 2>/dev/null || true)
  if [ -n "$EXP_EPOCH" ]; then
    EXP_DATE=$(format_unix_to_date "$EXP_EPOCH" 2>/dev/null || true)
    if [ -n "$EXP_DATE" ]; then
      NOW_EPOCH=$(date -u +%s)
      if [ "$EXP_EPOCH" -gt "$NOW_EPOCH" ]; then
        # Pro active. Days remaining is forward-rounded (e.g. 23h59m left
        # still shows "1 days remaining" — rounding down to 0 feels worse
        # than slight over-count). Subtract first, divide by 86400.
        SECS_LEFT=$(( EXP_EPOCH - NOW_EPOCH ))
        DAYS_LEFT=$(( (SECS_LEFT + 86399) / 86400 ))
        TIER_LINE="Pro (expires ${EXP_DATE}, ${DAYS_LEFT} days remaining)"
        TIER_KIND="pro"
      else
        # Pro lapsed. Token is on disk + non-empty but the platform will
        # reject it — surface this prominently with the renew CTA.
        TIER_LINE="Free (Pro expired ${EXP_DATE} — visit ${UPGRADE_URL} to renew)"
        TIER_KIND="pro-expired"
        PRO_EXPIRED_FLAG=1
      fi
    else
      # Could format epoch to a number but date(1) flavour unavailable.
      TIER_LINE="Pro (expires UNKNOWN — could not parse token)"
      TIER_KIND="pro"
    fi
  else
    # Token shape passed `license_token_looks_valid` but JWT parse failed.
    # Treat as Pro for display; the platform is the source of truth, and
    # if the token really is junk the user will see a 401 on the next call.
    TIER_LINE="Pro (expires UNKNOWN — could not parse token)"
    TIER_KIND="pro"
  fi
else
  TIER_LINE="Free (no Pro license configured)"
  TIER_KIND="free"
fi

# Emit the status block.
echo "OK  endpoint=${ENDPOINT}"
if [ -n "$TENANT_ID" ]; then
  echo "OK  tenant_id=${TENANT_ID}"
else
  echo "WARN tenant_id=<not found at ${REG_FILE}>"
  echo "    Run /axonflow-recover <email> if you've lost your registration,"
  echo "    or remove ${REG_FILE} and reload Claude Code to re-register against ${ENDPOINT}."
fi
echo "OK  tier=${TIER_LINE}"
echo "OK  license_token=${TOKEN_DISPLAY}"
if [ "$TIER_KIND" = "free" ]; then
  echo "OK  upgrade_url=${UPGRADE_URL}"
  echo "    Paste your tenant_id above into the 'AxonFlow tenant ID' custom field at checkout."
elif [ "$PRO_EXPIRED_FLAG" -eq 1 ]; then
  echo "    Your Pro license token is on disk but its 'exp' has passed; the plugin will not"
  echo "    forward it on governed requests. After renewal, run /axonflow-login --token <new>."
fi

exit 0
