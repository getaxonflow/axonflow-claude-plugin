#!/usr/bin/env bash
# Source this in the shell that launches Claude Code. The hook can load the saved
# credential itself; Claude Code's static MCP header expansion needs exported env.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "[AxonFlow] Source this file before launching Claude Code: source scripts/hosted-env.sh" >&2
  exit 1
fi
if [ -n "${AXONFLOW_ENDPOINT:-}" ] || [ -n "${AXONFLOW_AUTH:-}" ] || [ -n "${AXONFLOW_MCP_AUTHORIZATION:-}" ]; then
  echo "[AxonFlow] Existing AxonFlow endpoint or auth configuration is set; leaving it untouched." >&2
  return 1
fi
file="${AXONFLOW_CONFIG_DIR:-${HOME}/.config/axonflow}/hosted-claude-code.json"
mode=$(stat -c %a "$file" 2>/dev/null) || mode=""
case "$mode" in
  ''|*[!0-9]*) mode=$(stat -f %Lp "$file" 2>/dev/null) || mode="" ;;
esac
if [ "$mode" != "600" ] && [ "$mode" != "0600" ]; then
  echo "[AxonFlow] Missing or unsafe credential file; run scripts/hosted-link.mjs first." >&2
  return 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[AxonFlow] jq is required to load the linked credential." >&2
  return 1
fi
tenant_id=$(jq -r '.tenant_id // empty' "$file" 2>/dev/null)
secret=$(jq -r '.secret // empty' "$file" 2>/dev/null)
endpoint=$(jq -r '.endpoint // empty' "$file" 2>/dev/null)
link_method=$(jq -r '.link_method // empty' "$file" 2>/dev/null)
expires_at=$(jq -r '.expires_at // empty' "$file" 2>/dev/null)
if [ "$link_method" != "portal-device" ] || [[ ! "$tenant_id" =~ ^cs_[0-9a-f-]{36}$ ]] ||
   [[ ! "$secret" =~ ^[0-9a-f]{64}$ ]] || [[ ! "$endpoint" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
  echo "[AxonFlow] Invalid linked credential; run scripts/hosted-link.mjs again." >&2
  return 1
fi
expires_epoch=$(date -d "$expires_at" +%s 2>/dev/null) || expires_epoch=""
case "$expires_epoch" in
  ''|*[!0-9]*) date_value="${expires_at%%.*}"; expires_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${date_value%Z}Z" +%s 2>/dev/null) || expires_epoch="" ;;
esac
case "$expires_epoch" in
  ''|*[!0-9]*) echo "[AxonFlow] Invalid credential expiry; re-link this installation." >&2; return 1 ;;
esac
if [ "$expires_epoch" -le "$(date +%s)" ]; then
  echo "[AxonFlow] Linked credential expired; re-link this installation." >&2
  return 1
fi
AXONFLOW_ENDPOINT="$endpoint"
AXONFLOW_AUTH=$(printf '%s:%s' "$tenant_id" "$secret" | base64 | tr -d '\n')
AXONFLOW_MCP_AUTHORIZATION="Basic $AXONFLOW_AUTH"
export AXONFLOW_ENDPOINT AXONFLOW_AUTH AXONFLOW_MCP_AUTHORIZATION
