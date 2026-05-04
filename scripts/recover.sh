#!/usr/bin/env bash
# /axonflow-recover slash-command implementation.
#
# POSTs the user's email to the AxonFlow agent's
# /api/v1/recover endpoint. The platform always returns 202 with a
# generic message — anti-enumeration. If a tenant is bound to that
# email, a magic link is sent.
#
# Endpoint resolution mirrors pre-tool-check.sh: AXONFLOW_ENDPOINT or
# AXONFLOW_AUTH set → self-hosted (AXONFLOW_ENDPOINT or localhost),
# otherwise Community SaaS at try.getaxonflow.com.
#
# Output is line-oriented:
#   OK   202 message="..."
#   ERR  <http_code> <body>
#
# Exit codes:
#   0 — request accepted by the platform (HTTP 202)
#   1 — non-202 response, network failure, or missing argument

set -uo pipefail

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  echo "ERR  Missing email argument. Usage: /axonflow-recover <email>" >&2
  exit 1
fi
EMAIL="$1"

# Minimal email shape check (matches platform's looksLikeEmail).
case "$EMAIL" in
  *@*.*) ;;
  *) echo "ERR  Argument does not look like an email address: $EMAIL" >&2; exit 1 ;;
esac

if ! command -v jq &>/dev/null; then
  echo "ERR  jq required for recovery flow but not on PATH" >&2
  exit 1
fi
if ! command -v curl &>/dev/null; then
  echo "ERR  curl required for recovery flow but not on PATH" >&2
  exit 1
fi

# Endpoint resolution (mirrors pre-tool-check.sh).
if [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
  ENDPOINT="https://try.getaxonflow.com"
else
  ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
fi

REQ_BODY=$(jq -n --arg e "$EMAIL" '{email: $e}')

# /api/v1/recover is unauthenticated by design (the user has lost their
# credentials, that's the whole point), so no auth headers needed here.
HTTP_RESP=$(curl -sS --max-time 10 -X POST "${ENDPOINT}/api/v1/recover" \
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

if [ "$CODE" = "202" ]; then
  MSG=$(echo "$BODY" | jq -r '.message // empty' 2>/dev/null)
  echo "OK   202 endpoint=${ENDPOINT} email=${EMAIL}"
  if [ -n "$MSG" ]; then
    echo "     ${MSG}"
  fi
  echo "     Next step: when you receive the magic-link email, copy the token=… value from the URL"
  echo "     and run /axonflow-recover-verify <token>."
  exit 0
fi

echo "ERR  ${CODE} endpoint=${ENDPOINT} body=${BODY}" >&2
exit 1
