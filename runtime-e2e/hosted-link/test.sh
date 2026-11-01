#!/usr/bin/env bash
# Manual real-Portal/real-Agent proof after staging is restored. Requires an
# owner to approve the printed device code in the verified staging browser.
set -euo pipefail

if [ "${AXONFLOW_HOSTED_E2E_PORTAL:-}" != "https://portal.try-staging.getaxonflow.com" ] ||
   [ "${AXONFLOW_HOSTED_E2E_ENDPOINT:-}" != "https://try-staging.getaxonflow.com" ]; then
  echo 'SKIP: set both exact staging Portal and Agent origins to run Hosted linking' >&2
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
export AXONFLOW_CONFIG_DIR="$WORK/config"

# The Portal approves a secret generated on this workstation; neither this
# script nor the browser receives a reusable credential from a public page.
HOME="$WORK/home" node "$ROOT/scripts/hosted-link.mjs" \
  --portal "$AXONFLOW_HOSTED_E2E_PORTAL" --endpoint "$AXONFLOW_HOSTED_E2E_ENDPOINT" \
  | tee "$WORK/link.out"
file="$AXONFLOW_CONFIG_DIR/hosted-claude-code.json"
test -f "$file"
mode=$(stat -c %a "$file" 2>/dev/null) || mode=""
case "$mode" in ''|*[!0-9]*) mode=$(stat -f %Lp "$file" 2>/dev/null) || mode="" ;; esac
test "$mode" = 600
jq -e '.link_method == "portal-device" and .endpoint == "https://try-staging.getaxonflow.com"' "$file" >/dev/null
secret=$(jq -r .secret "$file")
if grep -Fq "$secret" "$WORK/link.out"; then
  echo 'FAIL: link command printed the reusable secret' >&2
  exit 1
fi

# Source the exact setup used when launching the editor, then invoke its
# actual hook against the real staging Agent with a harmless synthetic call.
# shellcheck disable=SC2016
env -u AXONFLOW_ENDPOINT -u AXONFLOW_AUTH -u AXONFLOW_MCP_AUTHORIZATION \
  HOME="$WORK/home" AXONFLOW_CONFIG_DIR="$AXONFLOW_CONFIG_DIR" AXONFLOW_TELEMETRY=off \
  bash -c 'source "$1"; printf "%s\n" "$3" | bash "$2"' _ \
    "$ROOT/scripts/hosted-env.sh" "$ROOT/scripts/pre-tool-check.sh" \
    '{"tool_name":"Bash","tool_input":{"command":"echo axonflow-hosted-link-probe"}}' \
  >"$WORK/hook.out" 2>"$WORK/hook.err"
grep -Fq 'Connected to AxonFlow at https://try-staging.getaxonflow.com (mode=community-saas)' "$WORK/hook.err"
if grep -Eqi 'governance blocked|auth error|unauthorized' "$WORK/hook.err"; then
  echo 'FAIL: linked staging hook reported a governance/auth error' >&2
  exit 1
fi
if grep -Eqi '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"|governance.*(blocked|auth)' "$WORK/hook.out"; then
  echo 'FAIL: linked staging hook denied the benign probe' >&2
  exit 1
fi
echo 'PASS: approved device link, protected local credential, and linked staging hook'
