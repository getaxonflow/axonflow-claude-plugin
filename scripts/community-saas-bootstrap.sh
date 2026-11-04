#!/usr/bin/env bash
# Load an existing Community SaaS credential. New tenants link through the
# verified Hosted Portal; hook invocations must never create a tenant.
# shellcheck disable=SC2317

if [ "${AXONFLOW_MODE:-}" != "community-saas" ] || [ -n "${AXONFLOW_AUTH:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

CONFIG_DIR="${AXONFLOW_CONFIG_DIR:-${HOME}/.config/axonflow}"
LINKED_FILE="${CONFIG_DIR}/hosted-claude-code.json"
REGISTRATION_FILE="${CONFIG_DIR}/try-registration.json"
if [ "${AXONFLOW_MCP_HEADERS_HELPER:-0}" != "1" ] && [ -e "$LINKED_FILE" ]; then
  REGISTRATION_FILE="$LINKED_FILE"
fi

if [ ! -f "$REGISTRATION_FILE" ]; then
  PROMPT_DIR="${HOME}/.cache/axonflow"
  PROMPT_FILE="${PROMPT_DIR}/claude-code-plugin-hosted-link-shown"
  if [ ! -f "$PROMPT_FILE" ]; then
    echo "[AxonFlow] Set up Hosted at https://portal.try.getaxonflow.com/hosted/start, then run scripts/hosted-link.mjs and approve its code in the browser. No tenant was created by this hook." >&2
    mkdir -p "$PROMPT_DIR" 2>/dev/null && chmod 0700 "$PROMPT_DIR" 2>/dev/null
    (umask 077 && : > "$PROMPT_FILE") 2>/dev/null
  fi
  return 0 2>/dev/null || exit 0
fi

chmod 0700 "$CONFIG_DIR" 2>/dev/null
command -v jq >/dev/null 2>&1 || { return 0 2>/dev/null || exit 0; }
mode=$(stat -c %a "$REGISTRATION_FILE" 2>/dev/null) || mode=""
case "$mode" in
  ''|*[!0-9]*) mode=$(stat -f %Lp "$REGISTRATION_FILE" 2>/dev/null) || mode="" ;;
esac
if [ "$mode" != "600" ] && [ "$mode" != "0600" ]; then
  echo "[AxonFlow] $REGISTRATION_FILE has unsafe permissions ($mode); refusing to use it." >&2
  return 0 2>/dev/null || exit 0
fi

tenant_id=$(jq -r '.tenant_id // empty' "$REGISTRATION_FILE" 2>/dev/null)
secret=$(jq -r '.secret // empty' "$REGISTRATION_FILE" 2>/dev/null)
expires_at=$(jq -r '.expires_at // empty' "$REGISTRATION_FILE" 2>/dev/null)
saved_endpoint=$(jq -r '.endpoint // empty' "$REGISTRATION_FILE" 2>/dev/null)
if [ -z "$tenant_id" ] || [ -z "$secret" ] || [ -z "$expires_at" ]; then
  return 0 2>/dev/null || exit 0
fi
if [ -n "$saved_endpoint" ] && [ "$saved_endpoint" != "https://try.getaxonflow.com" ]; then
  echo "[AxonFlow] Linked credential targets another endpoint. Source scripts/hosted-env.sh before launching Claude Code." >&2
  return 0 2>/dev/null || exit 0
fi
expires_epoch=$(date -d "$expires_at" +%s 2>/dev/null) || expires_epoch=""
case "$expires_epoch" in
  ''|*[!0-9]*) date_value="${expires_at%%.*}"; expires_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${date_value%Z}Z" +%s 2>/dev/null) || expires_epoch="" ;;
esac
case "$expires_epoch" in
  ''|*[!0-9]*) return 0 2>/dev/null || exit 0 ;;
esac
if [ "$expires_epoch" -le "$(date +%s)" ]; then
  echo "[AxonFlow] Hosted credential expired. Re-link this installation through the verified Portal." >&2
  return 0 2>/dev/null || exit 0
fi

AXONFLOW_AUTH=$(printf '%s:%s' "$tenant_id" "$secret" | base64 | tr -d '\n')
export AXONFLOW_AUTH
return 0 2>/dev/null || exit 0
