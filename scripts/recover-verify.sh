#!/usr/bin/env bash
# /axonflow-recover-verify slash-command implementation.
#
# Consumes a magic-link recovery token by POSTing it to
# /api/v1/recover/verify, then atomically persists the returned
# {tenant_id, secret, secret_prefix, expires_at, endpoint, email, note}
# bundle to ~/.config/axonflow/try-registration.json so subsequent
# governed agent calls authenticate as the recovered tenant.
#
# Output is line-oriented:
#   OK   tenant_id=cs_... email=... endpoint=... expires_at=...
#   ERR  <http_code> <body> | <message>
#
# Exit codes:
#   0 — token consumed, new credentials persisted
#   1 — non-200 response, network failure, write failure, or missing argument
#
# Persists to the SAME file the Community-SaaS bootstrap reads, so the
# next hook invocation will pick up the new credentials automatically.

set -uo pipefail

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  echo "ERR  Missing token argument. Usage: /axonflow-recover-verify <token>" >&2
  exit 1
fi
TOKEN="$1"

if [ "${#TOKEN}" -lt 32 ]; then
  echo "ERR  Token looks too short (length=${#TOKEN}). Magic-link tokens are 64-char hex strings; copy the token=… value from the URL, not the whole URL." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERR  jq required for recovery flow but not on PATH" >&2
  exit 1
fi
if ! command -v curl &>/dev/null; then
  echo "ERR  curl required for recovery flow but not on PATH" >&2
  exit 1
fi

# Endpoint resolution (mirrors pre-tool-check.sh / recover.sh).
if [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
  ENDPOINT="https://try.getaxonflow.com"
else
  ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
fi

REQ_BODY=$(jq -n --arg t "$TOKEN" '{token: $t}')

# POST consumes the token (GET would just render the HTML confirmation
# page). /api/v1/recover/verify is unauthenticated by design — the
# token IS the auth.
HTTP_RESP=$(curl -sS --max-time 10 -X POST "${ENDPOINT}/api/v1/recover/verify" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d "$REQ_BODY" \
  -w "\n%{http_code}" 2>/dev/null)
CURL_EXIT=$?

if [ "$CURL_EXIT" -ne 0 ]; then
  echo "ERR  Network failure talking to ${ENDPOINT} (curl exit $CURL_EXIT)" >&2
  exit 1
fi

CODE=$(echo "$HTTP_RESP" | tail -n1)
BODY=$(echo "$HTTP_RESP" | sed '$d')

if [ "$CODE" != "200" ]; then
  ERR_MSG=$(echo "$BODY" | jq -r '.error // empty' 2>/dev/null)
  if [ -n "$ERR_MSG" ]; then
    echo "ERR  ${CODE} ${ERR_MSG}" >&2
  else
    echo "ERR  ${CODE} ${BODY}" >&2
  fi
  if [ "$CODE" = "401" ]; then
    echo "     Token may be invalid, expired (15-min TTL), or already consumed." >&2
    echo "     Request a new magic link with /axonflow-recover <email>." >&2
  fi
  exit 1
fi

# Validate response shape before persisting.
TENANT_ID=$(echo "$BODY" | jq -r '.tenant_id // empty' 2>/dev/null)
SECRET=$(echo "$BODY" | jq -r '.secret // empty' 2>/dev/null)
SECRET_PREFIX=$(echo "$BODY" | jq -r '.secret_prefix // empty' 2>/dev/null)
EXPIRES_AT=$(echo "$BODY" | jq -r '.expires_at // empty' 2>/dev/null)
RECOVERED_ENDPOINT=$(echo "$BODY" | jq -r '.endpoint // empty' 2>/dev/null)
EMAIL=$(echo "$BODY" | jq -r '.email // empty' 2>/dev/null)
NOTE=$(echo "$BODY" | jq -r '.note // empty' 2>/dev/null)

if [ -z "$TENANT_ID" ] || [ -z "$SECRET" ] || [ -z "$EXPIRES_AT" ]; then
  echo "ERR  Recovery succeeded (HTTP 200) but response is missing tenant_id/secret/expires_at. Body: ${BODY}" >&2
  exit 1
fi

# Persist to ~/.config/axonflow/try-registration.json — same file the
# Community-SaaS bootstrap reads on every hook invocation. Atomic write
# with 0600 perms inside a 0700 directory.
CONFIG_DIR="${HOME}/.config/axonflow"
REG_FILE="${CONFIG_DIR}/try-registration.json"
mkdir -p "$CONFIG_DIR" 2>/dev/null && chmod 0700 "$CONFIG_DIR" 2>/dev/null
TMP="${REG_FILE}.tmp.$$"
if (umask 077 && jq -n \
      --arg tid "$TENANT_ID" \
      --arg sec "$SECRET" \
      --arg sp  "$SECRET_PREFIX" \
      --arg exp "$EXPIRES_AT" \
      --arg ep  "${RECOVERED_ENDPOINT:-$ENDPOINT}" \
      --arg em  "$EMAIL" \
      --arg note "$NOTE" \
      '{tenant_id: $tid, secret: $sec, secret_prefix: $sp, expires_at: $exp, endpoint: $ep, email: $em, note: $note, source: "recover-verify"}' \
      > "$TMP" 2>/dev/null) \
   && mv -f "$TMP" "$REG_FILE" 2>/dev/null; then
  :
else
  rm -f "$TMP" 2>/dev/null
  echo "ERR  Recovery succeeded but failed to persist credentials to $REG_FILE — run chmod 700 ~/.config/axonflow and retry, or save manually:" >&2
  echo "     tenant_id=${TENANT_ID}" >&2
  echo "     secret=${SECRET}" >&2
  exit 1
fi

echo "OK   tenant_id=${TENANT_ID} email=${EMAIL} endpoint=${RECOVERED_ENDPOINT:-$ENDPOINT} expires_at=${EXPIRES_AT}"
echo "     secret_prefix=${SECRET_PREFIX} (full secret persisted to $REG_FILE)"
echo "     ${NOTE}"
echo "     Previous tenant's audit history stays accessible under its old tenant_id"
echo "     for the documented retention window."
exit 0
