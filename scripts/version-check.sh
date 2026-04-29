#!/usr/bin/env bash
# Plugin/platform version compatibility check — runs once per install.
#
# Queries the AxonFlow agent's /health endpoint (advertised since
# platform v7.5.0 via axonflow-enterprise#1764) and compares the
# plugin's runtime version to plugin_compatibility.min_plugin_version
# ["claude"]. Logs a single warning to stderr if the plugin is below
# the floor the platform expects. Mirrors the SDK pattern that has run
# on every SDK client construction since v4.8.0.
#
# Stamp file at $HOME/.cache/axonflow/claude-plugin-version-check-stamp
# prevents repeat warnings. Delete the stamp file to re-check on next
# hook invocation. AXONFLOW_PLUGIN_VERSION_CHECK=off skips the check
# entirely (separate from telemetry opt-out — this is not telemetry).
#
# This script NEVER exits non-zero — all errors are silently swallowed.
# It NEVER blocks hook execution (called with & from pre-tool-check.sh).

# Dependencies — exit silently if missing
command -v curl &>/dev/null || exit 0
command -v jq &>/dev/null || exit 0

if [ "${AXONFLOW_PLUGIN_VERSION_CHECK:-}" = "off" ]; then
  exit 0
fi

# Stamp file guard — only check once per install
STAMP_DIR="${HOME}/.cache/axonflow"
STAMP_FILE="${STAMP_DIR}/claude-plugin-version-check-stamp"

if [ -f "$STAMP_FILE" ]; then
  exit 0
fi

mkdir -p "$STAMP_DIR" 2>/dev/null || exit 0

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ID="claude"

PLUGIN_VERSION=$(jq -r '.version // empty' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null)
if [ -z "$PLUGIN_VERSION" ]; then
  # Can't determine plugin version — record the attempt and exit silently
  : > "$STAMP_FILE" 2>/dev/null || true
  exit 0
fi

HEALTH_BODY=$(curl -s --max-time 2 "${ENDPOINT}/health" 2>/dev/null)
if [ -z "$HEALTH_BODY" ]; then
  # Platform unreachable — don't stamp, retry next time
  exit 0
fi

MIN_VERSION=$(echo "$HEALTH_BODY" \
  | jq -r --arg id "$PLUGIN_ID" '.plugin_compatibility.min_plugin_version[$id] // empty' 2>/dev/null)
RECOMMENDED_VERSION=$(echo "$HEALTH_BODY" \
  | jq -r --arg id "$PLUGIN_ID" '.plugin_compatibility.recommended_plugin_version[$id] // empty' 2>/dev/null)

# Older platform doesn't advertise plugin_compatibility — stamp and exit
# (no signal is not a regression; same posture SDKs use).
if [ -z "$MIN_VERSION" ] && [ -z "$RECOMMENDED_VERSION" ]; then
  : > "$STAMP_FILE" 2>/dev/null || true
  exit 0
fi

# compare_versions a b → echoes -1 / 0 / 1 for a<b / a==b / a>b
# Strips leading 'v', drops pre-release/build segments, pads to 3 parts.
compare_versions() {
  local a="${1#v}"
  local b="${2#v}"
  a="${a%%[-+]*}"
  b="${b%%[-+]*}"
  local IFS=.
  read -r -a aa <<<"$a"
  read -r -a bb <<<"$b"
  local i
  for i in 0 1 2; do
    local av="${aa[$i]:-0}"
    local bv="${bb[$i]:-0}"
    av=$((10#${av:-0}))
    bv=$((10#${bv:-0}))
    if [ "$av" -lt "$bv" ]; then echo -1; return; fi
    if [ "$av" -gt "$bv" ]; then echo 1; return; fi
  done
  echo 0
}

if [ -n "$MIN_VERSION" ]; then
  cmp=$(compare_versions "$PLUGIN_VERSION" "$MIN_VERSION")
  if [ "$cmp" = "-1" ]; then
    echo "[axonflow] Plugin v${PLUGIN_VERSION} is below the platform's minimum supported version (v${MIN_VERSION}). Upgrade with \`claude plugin update axonflow\` — older releases may mis-handle newer platform contract fields." >&2
    : > "$STAMP_FILE" 2>/dev/null || true
    exit 0
  fi
fi

if [ -n "$RECOMMENDED_VERSION" ]; then
  cmp=$(compare_versions "$PLUGIN_VERSION" "$RECOMMENDED_VERSION")
  if [ "$cmp" = "-1" ]; then
    echo "[axonflow] Plugin v${PLUGIN_VERSION} is below the recommended version (v${RECOMMENDED_VERSION}). Plugin will keep working; upgrade for the full feature set." >&2
  fi
fi

: > "$STAMP_FILE" 2>/dev/null || true
exit 0
