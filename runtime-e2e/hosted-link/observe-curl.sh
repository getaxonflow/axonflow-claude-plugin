#!/usr/bin/env bash
# Forward the hook's real curl call and record only a valid Agent allow decision.
# The hook remains unchanged; its fail-open transport path cannot create proof.

args=("$@")
body=""
payload=""
url=""
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    -o|--output) body="${args[i+1]:-}" ;;
    -d|--data|--data-raw) payload="${args[i+1]:-}" ;;
    https://*|http://*) url="${args[i]}" ;;
  esac
done

if [ "$url" != "${AXONFLOW_E2E_AGENT_ORIGIN}/api/v1/mcp-server" ] ||
   [ -z "$body" ] ||
   ! printf '%s' "$payload" | jq -e '.jsonrpc == "2.0" and .id == "hook-pre" and .method == "tools/call" and .params.name == "check_policy"' >/dev/null 2>&1; then
  exec "$AXONFLOW_E2E_REAL_CURL" "${args[@]}"
fi

status=$("$AXONFLOW_E2E_REAL_CURL" "${args[@]}")
result=$?
printf '%s' "$status"
if [ "$result" -ne 0 ] && [ -n "${AXONFLOW_E2E_TRANSPORT_FILE:-}" ]; then
  printf '%s\n' "$result" > "$AXONFLOW_E2E_TRANSPORT_FILE"
fi
if [ "$result" -eq 0 ] && [ "$status" = 200 ] && [ -s "$body" ] &&
   jq -e '.jsonrpc == "2.0" and .id == "hook-pre" and .result.isError != true and (.result.content[0].text | fromjson | .allowed == true)' "$body" >/dev/null 2>&1; then
  printf 'allowed\n' > "$AXONFLOW_E2E_DECISION_FILE"
fi
exit "$result"
