#!/usr/bin/env bash
# Community-SaaS first-run bootstrap.
#
# When the plugin is in Community-SaaS mode (no explicit user config —
# neither AXONFLOW_ENDPOINT nor AXONFLOW_AUTH set), this script ensures
# the plugin has registered against try.getaxonflow.com and exports the
# resulting Basic-auth credential so the calling hook can authenticate.
#
# Caller contract:
#   . scripts/community-saas-bootstrap.sh   (sourced, not invoked)
# After sourcing, if AXONFLOW_MODE=community-saas was set on entry, the
# AXONFLOW_AUTH variable is exported with the bootstrapped credential
# whenever a valid registration is on disk. If bootstrap fails (network
# down, 429 rate-limited, etc.), AXONFLOW_AUTH remains unset and the
# caller is responsible for surfacing a clear "governance degraded"
# notice — see pre-tool-check.sh.
#
# Design rules (per feedback_telemetry_heartbeat_design_rules.md):
#   - Stamp-on-delivery: registration file is written ONLY after the
#     POST returns 201 with a parseable response body. A failure mid-
#     registration leaves the file in its previous (or absent) state.
#   - Atomic writes: temp + rename so a crash mid-write never produces
#     a half-written, half-readable file.
#   - In-flight gate: flock prevents two concurrent hook invocations
#     from both racing to register and creating duplicate cs_* tenants
#     against try.getaxonflow.com.
#   - File permissions: 0700 on the directory, 0600 on the registration
#     file. The file contains the plain-text credential; world-readable
#     would be a real security issue.
#   - 429 (registration rate-limit) → write a short backoff stamp and
#     exit cleanly. Next call after the backoff expires retries.
#
# Never exits non-zero. Never blocks the calling hook.

# Skip unless caller has determined we're in Community-SaaS mode.
if [ "${AXONFLOW_MODE:-}" != "community-saas" ]; then
  return 0 2>/dev/null || exit 0
fi

# Dependencies — exit silently if missing.
command -v curl &>/dev/null || { return 0 2>/dev/null || exit 0; }
command -v jq &>/dev/null || { return 0 2>/dev/null || exit 0; }
# flock is Linux-only (not in stock macOS). Fall back to a mkdir-based
# atomic lock when it's missing; a single concurrent registration is fine.
HAS_FLOCK=1
command -v flock &>/dev/null || HAS_FLOCK=0

CONFIG_DIR="${HOME}/.config/axonflow"
REGISTRATION_FILE="${CONFIG_DIR}/try-registration.json"
LOCK_FILE="${CONFIG_DIR}/try-registration.lock"
LOCK_DIR="${CONFIG_DIR}/try-registration.lock.d"
BACKOFF_FILE="${HOME}/.cache/axonflow/claude-code-plugin-register-backoff"
ENDPOINT="https://try.getaxonflow.com"
REGISTER_URL="${ENDPOINT}/api/v1/register"

# Tighten the config dir at every invocation. mkdir -p -m 0700 only sets
# mode on directories it creates, NOT on existing ones. Re-chmod is a
# small but important defence: a user with .config at 0755 (the conv-
# entional default) would otherwise hold our 0600 credential file inside
# a traversable directory. The credential mode protects against other
# UIDs reading the file directly, but the directory mode is the second
# layer of defence advertised by the CHANGELOG.
mkdir -p "$CONFIG_DIR" 2>/dev/null && chmod 0700 "$CONFIG_DIR" 2>/dev/null
mkdir -p "$(dirname "$BACKOFF_FILE")" 2>/dev/null && chmod 0700 "$(dirname "$BACKOFF_FILE")" 2>/dev/null

NOW=$(date +%s)

# Helper: safely export AXONFLOW_AUTH from the registration file.
# Refuses to read a file with non-0600 permissions to prevent a
# world-readable credential leak from going unnoticed.
load_registration_into_env() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 1
  fi
  local mode
  mode=$(stat -f %Lp "$file" 2>/dev/null || stat -c %a "$file" 2>/dev/null || echo "")
  if [ "$mode" != "600" ] && [ "$mode" != "0600" ]; then
    echo "[AxonFlow] $file has unsafe permissions ($mode); refusing to use. Re-register: rm '$file' && retry" >&2
    return 1
  fi
  local tenant_id secret
  tenant_id=$(jq -r '.tenant_id // empty' "$file" 2>/dev/null)
  secret=$(jq -r '.secret // empty' "$file" 2>/dev/null)
  if [ -z "$tenant_id" ] || [ -z "$secret" ]; then
    return 1
  fi
  AXONFLOW_AUTH=$(printf '%s:%s' "$tenant_id" "$secret" | base64 | tr -d '\n')
  export AXONFLOW_AUTH
  return 0
}

# Helper: is the on-disk registration still usable? Treat as "needs refresh"
# when expires_at is within 30 days so we never let a tenant lapse silently.
registration_is_fresh() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 1
  fi
  local expires_at
  expires_at=$(jq -r '.expires_at // empty' "$file" 2>/dev/null)
  [ -z "$expires_at" ] && return 1
  # expires_at is RFC3339; convert to epoch via gdate (BSD) or date (GNU).
  local expires_epoch
  expires_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${expires_at%%.*}Z" "+%s" 2>/dev/null \
    || date -d "$expires_at" "+%s" 2>/dev/null \
    || echo 0)
  [ "$expires_epoch" -le 0 ] && return 1
  local thirty_days=$((30 * 24 * 60 * 60))
  [ $((expires_epoch - NOW)) -lt "$thirty_days" ] && return 1
  return 0
}

# Fast path: existing registration is still good. Load and return.
if registration_is_fresh "$REGISTRATION_FILE"; then
  load_registration_into_env "$REGISTRATION_FILE" >/dev/null && return 0 2>/dev/null
fi

# Backoff path: if a recent 429 told us to back off, honour it without trying.
if [ -f "$BACKOFF_FILE" ]; then
  backoff_until=$(cat "$BACKOFF_FILE" 2>/dev/null)
  if [ -n "$backoff_until" ] && [ "$backoff_until" -gt "$NOW" ] 2>/dev/null; then
    return 0 2>/dev/null || exit 0
  fi
fi

# In-flight gate: another hook may already be registering. If so, skip.
# Linux uses flock(1); macOS doesn't ship flock so we fall back to a
# mkdir-based atomic lock (POSIX-portable: mkdir is atomic w.r.t. itself).
LOCK_HELD=0
if [ "$HAS_FLOCK" = "1" ]; then
  exec 8>"$LOCK_FILE" 2>/dev/null || { return 0 2>/dev/null || exit 0; }
  if ! flock -n 8 2>/dev/null; then
    return 0 2>/dev/null || exit 0
  fi
  LOCK_HELD=1
else
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Another bootstrap is in flight, OR a stale lockdir from a crashed
    # previous run. Treat lockdirs older than 5 minutes as stale and
    # reclaim them — registration takes ~1s so this is generous.
    LOCK_MTIME=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
    case "$LOCK_MTIME" in
      ''|*[!0-9]*) LOCK_MTIME=0 ;;
    esac
    if [ "$LOCK_MTIME" -gt 0 ] && [ $((NOW - LOCK_MTIME)) -gt 300 ]; then
      rm -rf "$LOCK_DIR" 2>/dev/null
      mkdir "$LOCK_DIR" 2>/dev/null || { return 0 2>/dev/null || exit 0; }
    else
      return 0 2>/dev/null || exit 0
    fi
  fi
  LOCK_HELD=2
fi
# Single EXIT trap covers BOTH the optional mkdir lockdir AND the
# tempfiles below. Defining it once here avoids the second `trap` below
# from clobbering the lockdir-cleanup we'd otherwise install separately.
cleanup_on_exit() {
  [ -n "${HTTP_CODE_FILE:-}" ] && rm -f "$HTTP_CODE_FILE" 2>/dev/null
  [ -n "${RESPONSE_BODY_FILE:-}" ] && rm -f "$RESPONSE_BODY_FILE" 2>/dev/null
  [ "$LOCK_HELD" = "2" ] && rm -rf "$LOCK_DIR" 2>/dev/null
  return 0
}
trap cleanup_on_exit EXIT

# Re-check freshness inside the lock — a peer process may have just registered.
if registration_is_fresh "$REGISTRATION_FILE"; then
  load_registration_into_env "$REGISTRATION_FILE" >/dev/null && return 0 2>/dev/null
fi

# Build the label once. Keep it under 255 chars (server-side limit).
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PLUGIN_VERSION=$(jq -r '.version // "unknown"' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo "unknown")
LABEL="claude-code-plugin@${PLUGIN_VERSION} / $(uname -s)-$(uname -m)"

# Issue the registration. --fail returns non-zero on HTTP 4xx/5xx so we
# can distinguish 201/200 from 429 and other failures via curl exit code.
# Tempfile cleanup is handled by the cleanup_on_exit trap installed earlier.
HTTP_CODE_FILE="$(mktemp 2>/dev/null)" || { return 0 2>/dev/null || exit 0; }
RESPONSE_BODY_FILE="$(mktemp 2>/dev/null)" || { return 0 2>/dev/null || exit 0; }

curl -sS --max-time 10 -o "$RESPONSE_BODY_FILE" -w "%{http_code}" \
  -X POST "$REGISTER_URL" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg label "$LABEL" '{label: $label}')" \
  >"$HTTP_CODE_FILE" 2>/dev/null

HTTP_CODE=$(cat "$HTTP_CODE_FILE" 2>/dev/null || echo "")

# 429 → record short backoff window; honour it on subsequent invocations.
if [ "$HTTP_CODE" = "429" ]; then
  BACKOFF_UNTIL=$((NOW + 3600))
  (umask 077 && echo "$BACKOFF_UNTIL" > "$BACKOFF_FILE" 2>/dev/null)
  echo "[AxonFlow] Community SaaS registration rate-limited; will retry after $(date -r "$BACKOFF_UNTIL" 2>/dev/null || echo "1h")." >&2
  return 0 2>/dev/null || exit 0
fi

# Anything other than 201 → leave previous state (if any) untouched. The
# caller sees AXONFLOW_AUTH unset and surfaces the "governance degraded" notice.
if [ "$HTTP_CODE" != "201" ]; then
  return 0 2>/dev/null || exit 0
fi

# Validate the response shape before persisting. A malformed response should
# never overwrite a previously-good registration file.
TENANT_ID=$(jq -r '.tenant_id // empty' "$RESPONSE_BODY_FILE" 2>/dev/null)
SECRET=$(jq -r '.secret // empty' "$RESPONSE_BODY_FILE" 2>/dev/null)
if [ -z "$TENANT_ID" ] || [ -z "$SECRET" ]; then
  return 0 2>/dev/null || exit 0
fi

# Stamp-on-delivery: write atomically only after a fully-validated response.
TMP="${REGISTRATION_FILE}.tmp.$$"
if (umask 077 && cat "$RESPONSE_BODY_FILE" > "$TMP" 2>/dev/null) && mv -f "$TMP" "$REGISTRATION_FILE" 2>/dev/null; then
  rm -f "$BACKOFF_FILE" 2>/dev/null
  load_registration_into_env "$REGISTRATION_FILE" >/dev/null 2>&1
fi

return 0 2>/dev/null || exit 0
