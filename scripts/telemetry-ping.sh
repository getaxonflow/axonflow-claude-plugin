#!/usr/bin/env bash
# Anonymous telemetry heartbeat — fires at most once every 7 days per machine.
#
# Sends a POST to checkpoint.getaxonflow.com/v1/ping with plugin version,
# platform info (OS, arch, bash version), and AxonFlow platform version.
# No PII, no tool arguments, no policy data.
#
# Cadence design rules (per feedback_telemetry_heartbeat_design_rules.md):
#   1. Stamp-on-delivery, not stamp-on-attempt. The stamp file mtime is
#      advanced ONLY after curl returns 2xx. Transient network failures do
#      not silence telemetry for 7 days; the next active call retries.
#   2. In-flight gate via flock. When N concurrent hooks fire at once,
#      exactly one ping goes out — others fast-path past the lock.
#   3. Opt-out check FIRST, before any rate-limit cache or filesystem ops.
#      AXONFLOW_TELEMETRY=off toggled mid-process is honoured immediately.
#   4. mtime as the freshness source. The stamp file body holds the per-
#      machine instance_id (debug only); freshness comes from the timestamp.
#   5. Cross-platform stat: BSD (macOS) uses -f %m, GNU uses -c %Y. The
#      bash plugins ship on macOS/Linux only so the $HOME/.cache path is
#      portable enough.
#
# Opt out: AXONFLOW_TELEMETRY=off
#
# Note: DO_NOT_TRACK is intentionally not honored. Claude Code injects
# DO_NOT_TRACK=1 into every hook subprocess regardless of user intent.
#
# This script NEVER exits non-zero — errors are silently swallowed and
# never block hook execution (called with & from pre-tool-check.sh).

# Dependencies — exit silently if missing
command -v curl &>/dev/null || exit 0
command -v jq &>/dev/null || exit 0

# Step 1: opt-out check FIRST, before anything else.
if [ "${AXONFLOW_TELEMETRY:-}" = "off" ]; then
  exit 0
fi

STAMP_DIR="${HOME}/.cache/axonflow"
STAMP_FILE="${STAMP_DIR}/claude-code-plugin-telemetry-sent"
LOCK_FILE="${STAMP_DIR}/claude-code-plugin-telemetry.lock"
HEARTBEAT_INTERVAL_SECS=$((7 * 24 * 60 * 60))

# Best-effort mkdir; if it fails (no HOME, read-only fs) we treat as
# "no stamp" and a single ping fires per process. No crash.
mkdir -p -m 0700 "$STAMP_DIR" 2>/dev/null

# Step 2: pre-lock mtime check. Cheap exit when stamp is fresh.
NOW=$(date +%s)
stamp_mtime() {
  if [ -f "$STAMP_FILE" ]; then
    stat -f %m "$STAMP_FILE" 2>/dev/null || stat -c %Y "$STAMP_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

is_fresh() {
  local mtime="$1"
  if [ "$mtime" -gt 0 ] && [ "$mtime" -le "$NOW" ]; then
    local age=$((NOW - mtime))
    if [ "$age" -lt "$HEARTBEAT_INTERVAL_SECS" ]; then
      return 0
    fi
  fi
  # Future-dated stamp (clock-skew defence) or unreadable mtime → not fresh.
  return 1
}

if is_fresh "$(stamp_mtime)"; then
  exit 0
fi

# Step 3: in-flight gate via non-blocking flock. First concurrent invocation
# wins; the rest fast-path. Lock auto-releases when fd 9 closes on exit.
exec 9>"$LOCK_FILE" 2>/dev/null || exit 0
if ! flock -n 9 2>/dev/null; then
  exit 0
fi

# Step 4: re-check mtime after acquiring the lock. Between the pre-lock check
# and now, a peer process could have completed the heartbeat.
if is_fresh "$(stamp_mtime)"; then
  exit 0
fi

# Step 5: preserve the per-machine instance_id across heartbeats so successive
# pings from the same machine correlate. New instance_id only on first install
# (stamp absent) or after the cache is wiped.
INSTANCE_ID=""
if [ -f "$STAMP_FILE" ]; then
  INSTANCE_ID=$(head -1 "$STAMP_FILE" 2>/dev/null | tr -dc 'a-f0-9-' | head -c 64)
fi
if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "unknown")
  INSTANCE_ID=$(echo "$INSTANCE_ID" | tr '[:upper:]' '[:lower:]')
fi

# Step 6: resolve endpoint. AXONFLOW_MODE wins when set — pre-tool-check.sh
# exports it before sourcing the Community-SaaS bootstrap, and the bootstrap
# then exports AXONFLOW_AUTH but intentionally leaves AXONFLOW_ENDPOINT unset.
# Without honoring MODE here the AUTH-set check falls into the localhost
# branch, /health probes hit localhost, and the heartbeat ships
# platform_version=null for real Community-SaaS users.
if [ "${AXONFLOW_MODE:-}" = "community-saas" ]; then
  ENDPOINT="https://try.getaxonflow.com"
elif [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
  ENDPOINT="https://try.getaxonflow.com"
else
  ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
fi
CHECKPOINT_URL="${AXONFLOW_CHECKPOINT_URL:-https://checkpoint.getaxonflow.com/v1/ping}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SDK_VERSION=$(jq -r '.version // "unknown"' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo "unknown")

# /health probe is best-effort: 2s timeout, null on failure or missing field.
PLATFORM_VERSION=$(curl -s --max-time 2 "${ENDPOINT}/health" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || echo "")
if [ -z "$PLATFORM_VERSION" ] || [ "$PLATFORM_VERSION" = "null" ]; then
  PLATFORM_VERSION="null"
else
  PLATFORM_VERSION="\"${PLATFORM_VERSION}\""
fi

if [ "${AXONFLOW_MODE:-}" = "community-saas" ]; then
  DEPLOYMENT_MODE="community-saas"
elif [ -n "${AXONFLOW_AUTH:-}" ]; then
  DEPLOYMENT_MODE="production"
else
  DEPLOYMENT_MODE="development"
fi

HOOK_COUNT=0
HOOKS_FILE="$PLUGIN_DIR/hooks/hooks.json"
if [ -f "$HOOKS_FILE" ]; then
  HOOK_COUNT=$(jq '[.hooks[][]] | length' "$HOOKS_FILE" 2>/dev/null || echo "0")
fi

PAYLOAD=$(jq -n \
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
  }' 2>/dev/null)

if [ -z "$PAYLOAD" ]; then
  exit 0
fi

# Step 7: fire the heartbeat. --fail makes curl exit non-zero on HTTP 4xx/5xx
# so we know whether to advance the stamp. 3s timeout matches existing budget.
if curl -s --fail --max-time 3 -X POST "$CHECKPOINT_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" >/dev/null 2>&1; then
  # Step 8: stamp ONLY on delivery success. Atomic via temp+rename so a process
  # crash mid-write doesn't leave a corrupt stamp readable by the next caller.
  TMP="${STAMP_FILE}.tmp.$$"
  (umask 077 && echo "$INSTANCE_ID" > "$TMP" 2>/dev/null) && mv -f "$TMP" "$STAMP_FILE" 2>/dev/null
fi

exit 0
