#!/usr/bin/env bash
# Anonymous telemetry ping — fires once per install.
#
# Sends a single fire-and-forget POST to checkpoint.getaxonflow.com/v1/ping
# with plugin version, platform info (OS, arch, bash version), and AxonFlow
# platform version. No PII, no tool arguments, no policy data.
#
# Opt out: DO_NOT_TRACK=1 or AXONFLOW_TELEMETRY=off
#
# Guard: stamp file at $HOME/.cache/axonflow/claude-code-plugin-telemetry-sent
# prevents repeat pings. Delete the stamp file to re-send on next hook invocation.
#
# This script NEVER exits non-zero — all errors are silently swallowed.
# It NEVER blocks hook execution (called with & from pre-tool-check.sh).

# Dependencies — exit silently if missing
command -v curl &>/dev/null || exit 0
command -v jq &>/dev/null || exit 0

# Opt-out check (matches OpenClaw plugin's telemetry-config.ts)
if [ "${DO_NOT_TRACK:-}" = "1" ] || [ "${AXONFLOW_TELEMETRY:-}" = "off" ]; then
  exit 0
fi

# Stamp file guard — only send once per install
STAMP_DIR="${HOME}/.cache/axonflow"
STAMP_FILE="${STAMP_DIR}/claude-code-plugin-telemetry-sent"

if [ -f "$STAMP_FILE" ]; then
  exit 0
fi

# Create stamp directory and generate instance ID
mkdir -p "$STAMP_DIR" 2>/dev/null || exit 0
INSTANCE_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "unknown")
INSTANCE_ID=$(echo "$INSTANCE_ID" | tr '[:upper:]' '[:lower:]')
echo "$INSTANCE_ID" > "$STAMP_FILE" 2>/dev/null || exit 0

# Resolve configuration
ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
CHECKPOINT_URL="${AXONFLOW_CHECKPOINT_URL:-https://checkpoint.getaxonflow.com/v1/ping}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read plugin version from plugin.json
SDK_VERSION=$(jq -r '.version // "unknown"' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo "unknown")

# Detect platform version from /health endpoint (2s timeout, best-effort)
PLATFORM_VERSION=$(curl -s --max-time 2 "${ENDPOINT}/health" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || echo "")
if [ -z "$PLATFORM_VERSION" ] || [ "$PLATFORM_VERSION" = "null" ]; then
  PLATFORM_VERSION="null"
else
  PLATFORM_VERSION="\"${PLATFORM_VERSION}\""
fi

# Determine deployment mode
if [ -n "${AXONFLOW_AUTH:-}" ]; then
  DEPLOYMENT_MODE="production"
else
  DEPLOYMENT_MODE="development"
fi

# Count hooks from hooks.json (best-effort)
HOOK_COUNT=0
HOOKS_FILE="$PLUGIN_DIR/hooks/hooks.json"
if [ -f "$HOOKS_FILE" ]; then
  HOOK_COUNT=$(jq '[.hooks[][]] | length' "$HOOKS_FILE" 2>/dev/null || echo "0")
fi

# Build and send payload (3s timeout, fire-and-forget)
curl -s --max-time 3 -X POST "$CHECKPOINT_URL" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg sdk "claude-code-plugin" \
    --arg sdk_version "$SDK_VERSION" \
    --arg os "$(uname -s)" \
    --arg arch "$(uname -m)" \
    --arg runtime_version "${BASH_VERSION:-unknown}" \
    --arg deployment_mode "$DEPLOYMENT_MODE" \
    --arg instance_id "$INSTANCE_ID" \
    --argjson hook_count "$HOOK_COUNT" \
    --argjson platform_version "$PLATFORM_VERSION" \
    '{
      sdk: $sdk,
      sdk_version: $sdk_version,
      platform_version: $platform_version,
      os: $os,
      arch: $arch,
      runtime_version: $runtime_version,
      deployment_mode: $deployment_mode,
      features: ["hooks:\($hook_count)"],
      instance_id: $instance_id
    }')" > /dev/null 2>&1 || true

exit 0
