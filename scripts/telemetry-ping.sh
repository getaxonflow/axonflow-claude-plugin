#!/usr/bin/env bash
# Telemetry heartbeat — fires at most once every 7 days per machine.
#
# Sends a POST to checkpoint.getaxonflow.com/v1/ping with plugin version,
# platform info (OS, arch, bash version), the AxonFlow platform version, and
# the licence tier that platform reports about itself (a coarse bucket such as
# Community or Enterprise — no licence key, no expiry, no seat count, no
# customer name). No PII, no tool arguments, no policy data.
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
LOCK_DIR="${STAMP_DIR}/claude-code-plugin-telemetry.lock.d"
HEARTBEAT_INTERVAL_SECS=$((7 * 24 * 60 * 60))

# Best-effort mkdir + chmod; if it fails (no HOME, read-only fs) we treat
# as "no stamp" and a single ping fires per process. No crash. The chmod
# matters because mkdir -m only sets mode on directories it creates,
# leaving an existing 0755 .cache/axonflow with a 0755 mode.
mkdir -p "$STAMP_DIR" 2>/dev/null && chmod 0700 "$STAMP_DIR" 2>/dev/null

# Step 2: pre-lock mtime check. Cheap exit when stamp is fresh.
NOW=$(date +%s)
stamp_mtime() {
  if [ ! -f "$STAMP_FILE" ]; then
    echo 0
    return
  fi
  # GNU stat (Linux): -c %Y. BSD stat (macOS): -f %m. We can't blindly chain
  # them with `||` because GNU `stat -f %m FILE` doesn't fail — it treats
  # `%m` as a filesystem path and prints garbage with exit 0, which then
  # poisons the freshness check (non-numeric → `is_fresh` returns false →
  # the heartbeat fires every invocation). Try GNU first (CI is Linux),
  # validate numeric, then fall back to BSD; same validation.
  local out
  out=$(stat -c %Y "$STAMP_FILE" 2>/dev/null) || out=""
  case "$out" in
    ''|*[!0-9]*) ;;
    *) echo "$out"; return ;;
  esac
  out=$(stat -f %m "$STAMP_FILE" 2>/dev/null) || out=""
  case "$out" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$out" ;;
  esac
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

# Step 3: in-flight gate. flock(1) is Linux-only (not in stock macOS); fall
# back to a mkdir-based atomic lock. mkdir is POSIX-atomic, so two concurrent
# heartbeats can't both succeed at creating the lockdir. First wins, rest
# fast-path past. We also reclaim lockdirs older than 5 minutes (registration
# crashed mid-flight) so a single stale lockdir can't silence telemetry.
TELEMETRY_LOCK_HELD=0
if command -v flock &>/dev/null; then
  exec 9>"$LOCK_FILE" 2>/dev/null || exit 0
  if ! flock -n 9 2>/dev/null; then
    exit 0
  fi
  TELEMETRY_LOCK_HELD=1
else
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_MTIME=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
    case "$LOCK_MTIME" in
      ''|*[!0-9]*) LOCK_MTIME=0 ;;
    esac
    if [ "$LOCK_MTIME" -gt 0 ] && [ $((NOW - LOCK_MTIME)) -gt 300 ]; then
      rm -rf "$LOCK_DIR" 2>/dev/null
      mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    else
      exit 0
    fi
  fi
  TELEMETRY_LOCK_HELD=2
  trap '[ "$TELEMETRY_LOCK_HELD" = "2" ] && rm -rf "$LOCK_DIR" 2>/dev/null' EXIT
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
# Test-harness override for /health probe (tests/heartbeat-real-stack/).
# Production paths leave AXONFLOW_HARNESS unset.
if [ "${AXONFLOW_HARNESS:-}" = "1" ] && [ -n "${AXONFLOW_HARNESS_AGENT_ENDPOINT:-}" ]; then
  ENDPOINT="$AXONFLOW_HARNESS_AGENT_ENDPOINT"
fi
CHECKPOINT_URL="${AXONFLOW_CHECKPOINT_URL:-https://checkpoint.getaxonflow.com/v1/ping}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SDK_VERSION=$(jq -r '.version // "unknown"' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo "unknown")

# /health probe is best-effort: 2s timeout, ONE request. Both platform_version
# and license_tier are read from the SAME captured response body — this probe
# is not duplicated, and no new network call is introduced for license_tier.
# ADR-050 §4: even unauthenticated /health probes carry X-Axonflow-Client.
# (The Lambda checkpoint POST below is NOT to the agent — no header needed.)
#
# --fail makes curl discard the body and exit non-zero on 4xx/5xx, so a
# non-2xx /health contributes NEITHER field rather than having its error body
# parsed for one. This matches the openclaw plugin's `if (!resp.ok) return
# null` and is the only coherent posture once two fields share one body.
# It does not cost us the pre-init case: the agent answers HTTP 200 while
# still initializing and reports its state in the body ("status":"starting",
# "tier":"starting"), so that ping is still observed — see below.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/client-header.sh"
#
# The body is now held in a shell variable rather than streamed straight into
# jq. No size cap is applied, deliberately: a real /health is ~6 KB and is
# dominated by a `capabilities` map that grows every release, so any cap we
# picked would eventually start silently dropping BOTH fields with no
# diagnostic. jq already buffered the same document to parse it, the endpoint
# is the user's own configured agent, and the only part that reaches the wire
# is the tier string, which IS length-capped below.
HEALTH_BODY=$(curl -s --fail --max-time 2 -H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}" "${ENDPOINT}/health" 2>/dev/null || printf '')

PLATFORM_VERSION=$(printf '%s' "$HEALTH_BODY" | jq -r 'if type == "object" then (.version // empty) else empty end' 2>/dev/null || printf '')
# The literal string "null" is treated as unknown, preserving this field's
# prior behaviour.
if [ "$PLATFORM_VERSION" = "null" ]; then
  PLATFORM_VERSION=""
fi
# NOTE: this used to hand-build the JSON by splicing quotes around the value
# and passing it through --argjson. A /health answering with a version that
# CONTAINED a double quote or backslash then produced invalid JSON, jq -n
# failed, PAYLOAD came back empty, and the script exited 0 having sent NO
# HEARTBEAT AT ALL - a successful probe silently destroying the ping it was
# meant to enrich. It is now passed as a plain --arg and turned into
# null-or-string inside the filter, so jq owns the escaping. The wire shape is
# unchanged: JSON null when unknown, a JSON string otherwise.

# license_tier — the licence tier the PLATFORM reports about ITSELF, read from
# the `tier` key of the same /health response.
#
# THREE DIMENSIONS THAT SOUND ALIKE AND ARE NOT. Do not collapse any pair of
# them; each answers a different question and they disagree routinely:
#
#   license_tier    WHAT LICENCE THE PLATFORM SAYS IT IS RUNNING UNDER.
#                   Server-asserted — the plugin relays it and never derives,
#                   guesses, or corrects it. A self-hosted install pointed at
#                   by this plugin can be on any tier.
#   deployment_mode WHERE THIS PLUGIN IS POINTED, classified locally from the
#                   endpoint host (community_saas | self_hosted | unknown).
#                   Carries no licence information whatsoever: a self_hosted
#                   endpoint is routinely Enterprise, and community_saas is a
#                   hosting topology, not the "Community" tier.
#   endpoint_type   NETWORK REACHABILITY of that endpoint (localhost |
#                   private_network | remote). Carries neither of the above.
#
# The value is relayed VERBATIM and never normalized here. The receiver owns
# the canonical mapping, so a tier this build has never heard of still buckets
# correctly server-side instead of being flattened into "unknown" by a client
# that shipped before the tier existed. Values seen in practice today include
# the canonical set (Community / Evaluation / Professional / Enterprise /
# Plus), the lowercase "community" that community-mode builds default to, and
# "starting" — the transient pre-initialisation answer, which is a real and
# deliberately-reported state, not an error.
#
# OMITTED, never sent as "unknown", whenever the probe could not establish it:
# unreachable endpoint, non-2xx, malformed or non-object body, and a `tier`
# that is absent, blank, or not a string. Omission is the wire's existing
# "this client did not report" signal (the field is `omitempty` server-side);
# sending a literal "unknown" would instead assert that the platform answered
# and said it did not know, which is a different and false claim.
# The `type == "object"` half is defence in depth and deliberately NOT
# load-bearing: jq already errors when asked for `.tier` of an array, string or
# number, the error is swallowed, and the result is the same empty value. It is
# here so the non-object case reads as intended rather than accidental. The
# STRING check is the half that earns its keep. The mutation gate plants the
# object check's removal as a must-SURVIVE control, so if it ever becomes
# observable the gate says so instead of this comment quietly going stale.
LICENSE_TIER=$(printf '%s' "$HEALTH_BODY" | jq -r 'if type == "object" and (.tier | type) == "string" then .tier else empty end' 2>/dev/null || printf '')
# A hostile or broken endpoint controls this string. The canonical set is
# short ("EnterprisePlus" is the longest at 14 characters), so anything past
# 64 is not a tier: drop it rather than ship it, and drop rather than truncate
# — a truncated value would be a tier the platform never actually reported.
if [ "${#LICENSE_TIER}" -gt 64 ]; then
  LICENSE_TIER=""
fi

# v1 telemetry-schema (#2008) classifiers. deployment_mode is derived from
# the configured endpoint host plus the AXONFLOW_TRY=1 explicit override;
# endpoint_type follows the SDK ClassifyEndpoint shape so cross-client
# analytics dimensions stay consistent. Both functions return one of the
# fixed v1 allowlist values; "unknown" is preferred over silent fallback
# when input is missing/unparseable.
classify_deployment_mode() {
  local endpoint="$1"
  if [ "${AXONFLOW_TRY:-}" = "1" ]; then
    printf 'community_saas'
    return
  fi
  if [ -z "$endpoint" ]; then
    printf 'unknown'
    return
  fi
  local host
  host=$(printf '%s' "$endpoint" | sed -nE 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:?#]+).*#\1#p' | tr '[:upper:]' '[:lower:]')
  if [ -z "$host" ]; then
    printf 'unknown'
    return
  fi
  case "$host" in
    try.getaxonflow.com|*.try.getaxonflow.com)
      printf 'community_saas' ;;
    *)
      printf 'self_hosted' ;;
  esac
}

classify_endpoint_type() {
  local endpoint="$1"
  if [ -z "$endpoint" ]; then
    printf 'unknown'
    return
  fi
  local host
  host=$(printf '%s' "$endpoint" | sed -nE 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:?#]+).*#\1#p' | tr '[:upper:]' '[:lower:]')
  if [ -z "$host" ]; then
    printf 'unknown'
    return
  fi
  case "$host" in
    localhost|127.0.0.1|::1|0.0.0.0|*.localhost)
      printf 'localhost'; return ;;
    *.local|*.internal|*.lan|*.intranet)
      printf 'private_network'; return ;;
  esac
  case "$host" in
    10.*|192.168.*) printf 'private_network'; return ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) printf 'private_network'; return ;;
  esac
  printf 'remote'
}

DEPLOYMENT_MODE=$(classify_deployment_mode "$ENDPOINT")
ENDPOINT_TYPE=$(classify_endpoint_type "$ENDPOINT")

HOOK_COUNT=0
HOOKS_FILE="$PLUGIN_DIR/hooks/hooks.json"
if [ -f "$HOOKS_FILE" ]; then
  HOOK_COUNT=$(jq '[.hooks[][]] | length' "$HOOKS_FILE" 2>/dev/null || echo "0")
fi

# v9.1 deployment-organization identifier (#2277). Two sources, precedence
# order: ORG_ID env (operator-supplied on self-hosted) → tenant_id from
# ~/.config/axonflow/try-registration.json (Community SaaS cs_<uuid>) →
# "local-dev-org" sentinel. Always emitted.
REGISTRATION_FILE="${AXONFLOW_CONFIG_DIR:-${HOME}/.config/axonflow}/try-registration.json"
if [ -n "${ORG_ID:-}" ]; then
  ORG_ID_VALUE="$ORG_ID"
elif [ -f "$REGISTRATION_FILE" ]; then
  ORG_ID_VALUE=$(jq -r '.tenant_id // empty' "$REGISTRATION_FILE" 2>/dev/null)
  [ -z "$ORG_ID_VALUE" ] && ORG_ID_VALUE="local-dev-org"
else
  ORG_ID_VALUE="local-dev-org"
fi

PAYLOAD=$(jq -n \
  --arg telemetry_type "plugin" \
  --arg sdk "claude-code-plugin" \
  --arg sdk_version "$SDK_VERSION" \
  --arg os "$(uname -s)" \
  --arg arch "$(uname -m)" \
  --arg runtime_version "${BASH_VERSION:-unknown}" \
  --arg deployment_mode "$DEPLOYMENT_MODE" \
  --arg endpoint_type "$ENDPOINT_TYPE" \
  --arg instance_id "$INSTANCE_ID" \
  --arg org_id "$ORG_ID_VALUE" \
  --arg license_tier "$LICENSE_TIER" \
  --argjson hook_count "$HOOK_COUNT" \
  --arg platform_version "$PLATFORM_VERSION" \
  '{
    telemetry_type: $telemetry_type,
    sdk: $sdk,
    sdk_version: $sdk_version,
    platform_version: (if $platform_version == "" then null else $platform_version end),
    os: $os,
    arch: $arch,
    runtime_version: $runtime_version,
    deployment_mode: $deployment_mode,
    endpoint_type: $endpoint_type,
    features: ["hooks:\($hook_count)"],
    instance_id: $instance_id,
    org_id: $org_id
  }
  + (if $license_tier == "" then {} else { license_tier: $license_tier } end)' 2>/dev/null)

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
