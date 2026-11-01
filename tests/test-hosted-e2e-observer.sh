#!/usr/bin/env bash
# Local parser regression for the real-stack decision observer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/curl-fixture" <<'EOF'
#!/usr/bin/env bash
body=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[i]}" = -o ]; then body="${args[i+1]}"; fi
done
case "$RESPONSE_KIND" in
  allow) printf '%s' '{"jsonrpc":"2.0","id":"hook-pre","result":{"content":[{"text":"{\"allowed\":true}"}]}}' > "$body"; printf 200 ;;
  deny) printf '%s' '{"jsonrpc":"2.0","id":"hook-pre","result":{"content":[{"text":"{\"allowed\":false}"}]}}' > "$body"; printf 200 ;;
  missing) printf '%s' '{"jsonrpc":"2.0","id":"hook-pre","result":{"content":[{"text":"{}"}]}}' > "$body"; printf 200 ;;
  transport) printf 000; exit 7 ;;
esac
EOF
chmod 0700 "$WORK/curl-fixture"
export AXONFLOW_E2E_REAL_CURL="$WORK/curl-fixture"
export AXONFLOW_E2E_AGENT_ORIGIN=https://try-staging.getaxonflow.com
export AXONFLOW_E2E_DECISION_FILE="$WORK/decision"
export AXONFLOW_E2E_TRANSPORT_FILE="$WORK/transport"
payload='{"jsonrpc":"2.0","id":"hook-pre","method":"tools/call","params":{"name":"check_policy"}}'

for kind in allow deny missing transport; do
  rm -f "$WORK/decision" "$WORK/transport" "$WORK/body"
  export RESPONSE_KIND="$kind"
  result=0
  bash "$ROOT/runtime-e2e/hosted-link/observe-curl.sh" \
    -o "$WORK/body" -w '%{http_code}' \
    -X POST https://try-staging.getaxonflow.com/api/v1/mcp-server \
    -d "$payload" > "$WORK/status" || result=$?
  case "$kind" in
    allow) test "$result" -eq 0; test "$(cat "$WORK/status")" = 200; test "$(cat "$WORK/decision")" = allowed ;;
    deny|missing) test "$result" -eq 0; test ! -e "$WORK/decision" ;;
    transport) test "$result" -eq 7; test -s "$WORK/transport"; test ! -e "$WORK/decision" ;;
  esac
  echo "PASS observer $kind"
done

# Exercise the real hook's benign fail-open branch with a protected linked
# credential and a refused local proxy. The release observer must see the
# transport error and no Agent decision.
mkdir -p "$WORK/home" "$WORK/config" "$WORK/bin"
cp "$ROOT/runtime-e2e/hosted-link/observe-curl.sh" "$WORK/bin/curl"
chmod 0700 "$WORK/bin/curl"
cat > "$WORK/config/hosted-claude-code.json" <<'EOF'
{"tenant_id":"cs_12345678-1234-1234-1234-123456789abc","secret":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","endpoint":"https://try-staging.getaxonflow.com","link_method":"portal-device","expires_at":"2099-01-01T00:00:00Z"}
EOF
chmod 0600 "$WORK/config/hosted-claude-code.json"
rm -f "$WORK/decision" "$WORK/transport"
env -u AXONFLOW_ENDPOINT -u AXONFLOW_AUTH -u AXONFLOW_MCP_AUTHORIZATION \
  HOME="$WORK/home" AXONFLOW_CONFIG_DIR="$WORK/config" AXONFLOW_TELEMETRY=off \
  PATH="$WORK/bin:$PATH" AXONFLOW_E2E_REAL_CURL="$(command -v curl)" \
  AXONFLOW_E2E_AGENT_ORIGIN=https://try-staging.getaxonflow.com \
  AXONFLOW_E2E_DECISION_FILE="$WORK/decision" AXONFLOW_E2E_TRANSPORT_FILE="$WORK/transport" \
  HTTPS_PROXY=http://127.0.0.1:1 https_proxy=http://127.0.0.1:1 \
  ALL_PROXY= all_proxy= NO_PROXY= no_proxy= \
  bash -c 'source "$1"; printf "%s\n" "$3" | bash "$2"' _ \
    "$ROOT/scripts/hosted-env.sh" "$ROOT/scripts/pre-tool-check.sh" \
    '{"tool_name":"Bash","tool_input":{"command":"echo axonflow-hosted-link-probe"}}' \
  >"$WORK/hook.out" 2>"$WORK/hook.err"
test -s "$WORK/transport"
test ! -e "$WORK/decision"
echo 'PASS linked hook transport failure cannot satisfy release proof'
