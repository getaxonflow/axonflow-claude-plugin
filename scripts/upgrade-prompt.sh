#!/usr/bin/env bash
# V1 Plugin Pro upgrade-prompt envelope handling (umbrella getaxonflow/axonflow-enterprise#1958).
#
# Sourceable helpers used by the plugin's hook scripts to:
#   1. Detect the V1 Plugin Pro structured envelope on 429 / 403 responses
#      from the AxonFlow agent.
#   2. Surface the envelope's upgrade.wording to the operator on stderr,
#      with a once-per-day stamp so the message doesn't spam every hook.
#   3. Honor the Retry-After header by stamping a throttle-until file —
#      subsequent invocations short-circuit the network call locally
#      until the deadline passes (matches the deadline carried in the
#      envelope's resets_at). Prevents the silent-retry pattern that
#      generated 581 retries from one IP in 18h pre-envelope.
#
# All output goes to stderr; stdout is reserved for the Claude Code hook
# protocol (any byte on stdout from a non-deny path breaks the parser).
#
# Cache layout (mode 0700):
#   ~/.cache/axonflow/throttle-until                 — epoch deadline file
#   ~/.cache/axonflow/upgrade-prompt-last-shown      — date stamp (YYYY-MM-DD)
#
# Functions exported to callers:
#   axonflow_throttle_active            — exit 0 if throttle deadline still in future
#   axonflow_handle_envelope_response   — args: <http_code> <body_file> <headers_file>
#   axonflow_handle_auth_failure        — args: <http_code> <body_file> <headers_file>
#                                         Detects HTTP 401 and stamps a 5-minute
#                                         throttle. Prevents the auth-storm
#                                         retry loop documented in
#                                         axonflow-enterprise#2275 (716 × 401
#                                         in 24h from a single source IP when
#                                         credentials are expired/invalid).

# Guard against multi-source.
if [ -n "${_AXONFLOW_UPGRADE_PROMPT_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_AXONFLOW_UPGRADE_PROMPT_LOADED=1

_AXONFLOW_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/axonflow"
_AXONFLOW_THROTTLE_FILE="${_AXONFLOW_CACHE_DIR}/throttle-until"
_AXONFLOW_PROMPT_STAMP="${_AXONFLOW_CACHE_DIR}/upgrade-prompt-last-shown"
# Separate stamp file for the auth-failure (HTTP 401) nudge so a tier-limit
# upgrade prompt earlier in the day doesn't suppress a later credential-
# refresh nudge (and vice versa). They are independent operator concerns;
# co-locating them on the same once-per-day stamp would silently swallow
# whichever fires second. Matches the codex-plugin design and the cursor-
# plugin v1.5.2 follow-up. Regression guard: tests/test-upgrade-prompt.sh
# T13 pre-stamps `upgrade-prompt-last-shown` then asserts the 401 nudge
# still fires.
_AXONFLOW_AUTH_PROMPT_STAMP="${_AXONFLOW_CACHE_DIR}/auth-failure-prompt-last-shown"

# The stamp rules (axonflow-enterprise#4249, comment 5684124176). The
# throttle-until file is ONE line, `<epoch> <limit_type>`, and it is shared:
# the Cursor and Codex hooks (and, on Linux, the OpenClaw plugin) read and
# write the same file. Its write and its format are unchanged here; what
# changed is which stamps gate a governed call in these hooks:
#   1. of the limit stamps, only a request-rate limit (daily_quota,
#      per_minute) gates;
#   2. a feature or object-count limit (feature_pro_only, active_policies,
#      hitl_approvals_window, decision_list_size) shows its upgrade prompt
#      when it is answered and gates nothing;
#   3. a request-rate stamp is honoured for at most
#      _AXONFLOW_LIMIT_STAMP_MAX_HONOUR_SECONDS after its file was written,
#      then the hook asks the platform again (a local deny never sees a reset
#      or an upgrade; a hitl_approvals_window resets_at is a week out);
#   4. a stamp whose file was written more than
#      _AXONFLOW_STAMP_CLOCK_SKEW_SECONDS in the future counts as past the cap;
#   5. a stamp of another type, or past the cap, is left on disk: another
#      plugin that wrote it may still honour it;
#   6. the auth_failure cooldown a 401 stamps gates for its configured length
#      (AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS), counted from when its file was
#      written (rule 4's skew applies), not the 300-second limit cap and not the
#      deadline in the file.
_AXONFLOW_LIMIT_STAMP_MAX_HONOUR_SECONDS=300
_AXONFLOW_STAMP_CLOCK_SKEW_SECONDS=60

# Text from the network is cleaned before it is printed (axonflow_clean_text,
# scripts/lib/failure-posture.sh). The hooks source that file before this one;
# a script that sources this file on its own gets it here.
if ! command -v axonflow_clean_text >/dev/null 2>&1; then
  _axonflow_prompt_dir="${BASH_SOURCE[0]%/*}"
  if [ "$_axonflow_prompt_dir" = "${BASH_SOURCE[0]}" ]; then
    _axonflow_prompt_dir="."
  fi
  # shellcheck source=./lib/failure-posture.sh
  . "${_axonflow_prompt_dir}/lib/failure-posture.sh" 2>/dev/null
  unset _axonflow_prompt_dir
fi

_axonflow_ensure_cache_dir() {
  if [ ! -d "$_AXONFLOW_CACHE_DIR" ]; then
    mkdir -p "$_AXONFLOW_CACHE_DIR" 2>/dev/null && chmod 0700 "$_AXONFLOW_CACHE_DIR" 2>/dev/null
  fi
}

# axonflow_throttle_active
#   Returns 0 if a throttle deadline is in effect (current epoch < stamp).
#   Caller should skip outbound governed calls and fall open for this hook.
#   On first hook of a new throttle period the function also re-emits a
#   short stderr nudge so the operator sees they're in the back-off window.
axonflow_throttle_active() {
  if [ ! -f "$_AXONFLOW_THROTTLE_FILE" ]; then
    return 1
  fi
  local until_epoch
  until_epoch=$(awk 'NR==1 {print $1}' "$_AXONFLOW_THROTTLE_FILE" 2>/dev/null)
  # At most 18 digits: a longer number overflows bash arithmetic, so it is malformed.
  if [ -z "$until_epoch" ] || ! [[ "$until_epoch" =~ ^[0-9]{1,18}$ ]]; then
    rm -f "$_AXONFLOW_THROTTLE_FILE" 2>/dev/null
    return 1
  fi
  local now
  now=$(date -u +%s)
  if [ "$now" -lt "$until_epoch" ]; then
    return 0
  fi
  # Deadline passed — clear the stamp so the next call goes through normally.
  rm -f "$_AXONFLOW_THROTTLE_FILE" 2>/dev/null
  return 1
}

# _axonflow_file_mtime <file>
#   Prints the file's modification time as a UTC epoch (GNU stat, then BSD
#   stat), or nothing when it cannot be read.
_axonflow_file_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=""
  if ! [[ "$m" =~ ^[0-9]+$ ]]; then
    m=$(stat -f %m "$1" 2>/dev/null) || m=""
  fi
  [[ "$m" =~ ^[0-9]+$ ]] && echo "$m"
}

# axonflow_governed_stamp
#   Prints the stamp that gates a governed call now, and returns 0 when one
#   does: "auth_failure" (the 401 cooldown, for its configured length) or
#   "limit" (a request-rate limit written less than the cap ago, rules 1, 3
#   and 4 above). Prints nothing and returns 1 otherwise. An expired or
#   malformed stamp is cleared, as axonflow_throttle_active clears it; a stamp
#   of another type or past the cap is left on disk (rule 5).
axonflow_governed_stamp() {
  axonflow_throttle_active || return 1
  local limit_type written now
  limit_type=$(axonflow_throttle_limit_type)
  case "$limit_type" in
    auth_failure)
      # Rule 6, bounded: the cooldown gates for THIS hook's configured length
      # from when its file was written, with the same skew rule. The deadline
      # in the file is whatever the writer chose (another plugin's cooldown, a
      # stepped clock, a millisecond epoch), so it alone never decides.
      written=$(_axonflow_file_mtime "$_AXONFLOW_THROTTLE_FILE")
      [ -n "$written" ] || return 1
      now=$(date -u +%s)
      if [ $((written - now)) -gt "$_AXONFLOW_STAMP_CLOCK_SKEW_SECONDS" ] ||
         [ $((written + _AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS)) -le "$now" ]; then
        return 1
      fi
      echo auth_failure
      return 0
      ;;
    daily_quota|per_minute) ;;
    *) return 1 ;;
  esac
  written=$(_axonflow_file_mtime "$_AXONFLOW_THROTTLE_FILE")
  [ -n "$written" ] || return 1
  now=$(date -u +%s)
  if [ $((written - now)) -gt "$_AXONFLOW_STAMP_CLOCK_SKEW_SECONDS" ] ||
     [ $((written + _AXONFLOW_LIMIT_STAMP_MAX_HONOUR_SECONDS)) -le "$now" ]; then
    return 1
  fi
  echo limit
  return 0
}

# axonflow_throttle_remaining_seconds
#   Prints the seconds left before the throttle deadline passes (0 when there
#   is no deadline, or it has passed); for an auth_failure stamp, at most the
#   seconds left of this hook's configured cooldown (rule 6). The file is shared: every AxonFlow
#   plugin that uses this cache directory writes the same throttle-until, so
#   a block can outlast a credential fix, or come from another plugin's 401.
axonflow_throttle_remaining_seconds() {
  local until_epoch now
  until_epoch=$(awk 'NR==1 {print $1}' "$_AXONFLOW_THROTTLE_FILE" 2>/dev/null)
  if ! [[ "$until_epoch" =~ ^[0-9]{1,18}$ ]]; then
    echo 0
    return 0
  fi
  now=$(date -u +%s)
  if [ "$until_epoch" -le "$now" ]; then
    echo 0
    return 0
  fi
  local left=$((until_epoch - now)) written bound
  # An auth_failure cooldown gates here only for the configured length from
  # when its file was written (rule 6), so the seconds named are those.
  if [ "$(axonflow_throttle_limit_type)" = "auth_failure" ]; then
    written=$(_axonflow_file_mtime "$_AXONFLOW_THROTTLE_FILE")
    if [ -n "$written" ]; then
      bound=$((written + _AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS - now))
      [ "$bound" -lt 0 ] && bound=0
      [ "$bound" -lt "$left" ] && left=$bound
    fi
  fi
  echo "$left"
}

# axonflow_auth_cooldown_note
#   One sentence naming the auth-failure cooldown that is in effect: the
#   seconds left and the file to delete to retry at once after the fix.
axonflow_auth_cooldown_note() {
  echo "Governed tool calls stay blocked for another $(axonflow_throttle_remaining_seconds) seconds (the auth-failure cooldown in ${_AXONFLOW_THROTTLE_FILE}, which every AxonFlow plugin using that cache directory writes); after fixing the credential, delete that file to retry at once."
}

# _axonflow_should_show_prompt_today
#   Returns 0 if today's date stamp is missing (so we should show the
#   upgrade prompt at most once per UTC day).
_axonflow_should_show_prompt_today() {
  _axonflow_ensure_cache_dir
  local today
  today=$(date -u +%Y-%m-%d)
  if [ -f "$_AXONFLOW_PROMPT_STAMP" ]; then
    local last
    last=$(awk 'NR==1 {print $1}' "$_AXONFLOW_PROMPT_STAMP" 2>/dev/null)
    if [ "$last" = "$today" ]; then
      return 1
    fi
  fi
  echo "$today" >"$_AXONFLOW_PROMPT_STAMP" 2>/dev/null
  return 0
}

# _axonflow_should_show_auth_prompt_today
#   Returns 0 if today's date stamp is missing on the auth-failure prompt
#   (so we show the credential-refresh nudge at most once per UTC day).
#   Kept distinct from the upgrade-prompt stamp so a tier-limit nudge
#   earlier in the day doesn't suppress a later auth-failure nudge (and
#   vice versa) — they're independent operator concerns. Pre-1.5.2 used
#   the shared `_AXONFLOW_PROMPT_STAMP` here, which caused the 401 nudge
#   to be silently swallowed whenever the envelope handler had fired
#   earlier the same day (regression for axonflow-enterprise#2275).
_axonflow_should_show_auth_prompt_today() {
  _axonflow_ensure_cache_dir
  local today
  today=$(date -u +%Y-%m-%d)
  if [ -f "$_AXONFLOW_AUTH_PROMPT_STAMP" ]; then
    local last
    last=$(awk 'NR==1 {print $1}' "$_AXONFLOW_AUTH_PROMPT_STAMP" 2>/dev/null)
    if [ "$last" = "$today" ]; then
      return 1
    fi
  fi
  echo "$today" >"$_AXONFLOW_AUTH_PROMPT_STAMP" 2>/dev/null
  return 0
}

# _axonflow_iso8601_to_epoch <iso8601-string>
#   Converts an RFC 3339 / ISO 8601 timestamp to a UTC epoch.
#   Handles GNU date and BSD date (macOS). Echoes the epoch on success;
#   echoes empty + returns 1 on failure.
_axonflow_iso8601_to_epoch() {
  local ts="$1"
  [ -z "$ts" ] && return 1
  local epoch
  # GNU date
  epoch=$(date -u -d "$ts" +%s 2>/dev/null) && [ -n "$epoch" ] && {
    echo "$epoch"; return 0;
  }
  # BSD date (macOS) — strip 'Z' fractional seconds suffix variations
  local clean="${ts%Z}"
  clean="${clean%.*}"
  epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null) && [ -n "$epoch" ] && {
    echo "$epoch"; return 0;
  }
  return 1
}

# axonflow_handle_envelope_response <http_code> <body_file> <headers_file>
#   Detects the V1 Plugin Pro structured envelope on the response and, when
#   present:
#     - Emits upgrade.wording + buy URL to stderr (gated by once-per-day stamp)
#     - Stamps the throttle-until file so subsequent hooks answer locally
#       until the deadline passes (blocking while a hosted Free-tier limit
#       holds; ruled 2026-09-14)
#   Returns 0 if an envelope was detected and handled; 1 otherwise.
axonflow_handle_envelope_response() {
  local http_code="$1"
  local body_file="$2"
  local headers_file="$3"

  if [ -z "$http_code" ] || [ ! -f "$body_file" ]; then
    return 1
  fi

  # Only 429 and 403 carry the V1 envelope. Other statuses (200, 5xx, etc.)
  # are not envelope-bearing and are handled by the caller's existing logic.
  case "$http_code" in
    429|403) ;;
    *) return 1 ;;
  esac

  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  # The envelope can arrive in two shapes:
  #  (a) Direct HTTP body (429 daily-quota path, 403 non-MCP gates):
  #      `{ "error": ..., "limit_type": ..., "tier": ..., "upgrade": {...} }`
  #  (b) JSON-RPC wrapped (403 returned via /api/v1/mcp-server tools/call
  #      gates): `{ "result": { "content": [ {"type":"text","text":"<json>"}],
  #      "isError": true } }` where the text payload is the envelope.
  local limit_type wording buy_url resets_at
  limit_type=$(jq -r '.limit_type // empty' "$body_file" 2>/dev/null)
  if [ -z "$limit_type" ]; then
    # Try the JSON-RPC wrapped shape.
    local wrapped
    wrapped=$(jq -r '.result.content[0].text // empty' "$body_file" 2>/dev/null)
    if [ -n "$wrapped" ]; then
      limit_type=$(echo "$wrapped" | jq -r '.limit_type // empty' 2>/dev/null)
      wording=$(echo "$wrapped" | jq -r '.upgrade.wording // .error // empty' 2>/dev/null)
      buy_url=$(echo "$wrapped" | jq -r '.upgrade.buy_url // empty' 2>/dev/null)
      resets_at=$(echo "$wrapped" | jq -r '.resets_at // empty' 2>/dev/null)
    fi
  else
    wording=$(jq -r '.upgrade.wording // .error // empty' "$body_file" 2>/dev/null)
    buy_url=$(jq -r '.upgrade.buy_url // empty' "$body_file" 2>/dev/null)
    resets_at=$(jq -r '.resets_at // empty' "$body_file" 2>/dev/null)
  fi

  if [ -z "$limit_type" ]; then
    return 1
  fi

  # Stamp the throttle-until deadline. Prefer the envelope's resets_at (when
  # present); fall back to the Retry-After header. For object-count limits
  # (active_policies) and binary feature gates (feature_pro_only) neither
  # is set — use a short cooldown so we don't hammer the agent on retries.
  _axonflow_ensure_cache_dir
  local deadline_epoch=""
  if [ -n "$resets_at" ] && [ "$resets_at" != "null" ]; then
    deadline_epoch=$(_axonflow_iso8601_to_epoch "$resets_at" || true)
  fi
  if [ -z "$deadline_epoch" ] && [ -f "$headers_file" ]; then
    local retry_after
    retry_after=$(awk 'BEGIN{IGNORECASE=1} /^retry-after:/ {gsub(/\r/,""); print $2; exit}' "$headers_file" 2>/dev/null)
    if [ -n "$retry_after" ] && [[ "$retry_after" =~ ^[0-9]+$ ]]; then
      deadline_epoch=$(($(date -u +%s) + retry_after))
    fi
  fi
  if [ -z "$deadline_epoch" ]; then
    # No clock-driven deadline — short cooldown to avoid a tight retry loop.
    deadline_epoch=$(($(date -u +%s) + 60))
  fi
  echo "$deadline_epoch $limit_type" >"$_AXONFLOW_THROTTLE_FILE" 2>/dev/null
  _AXONFLOW_LAST_LIMIT_TYPE="$limit_type"

  # Emit the upgrade prompt at most once per UTC day so we don't spam every
  # hook fire. The throttle-until file ensures we still back off the network
  # immediately even when the prompt is suppressed.
  if _axonflow_should_show_prompt_today; then
    if [ -z "$wording" ]; then
      wording="Free tier limit reached on AxonFlow. Pro removes this cap."
    fi
    if [ -z "$buy_url" ]; then
      buy_url="https://getaxonflow.com/pricing/"
    fi
    {
      echo "[AxonFlow] $(axonflow_clean_text "$wording")"
      echo "[AxonFlow] Upgrade: $(axonflow_clean_text "$buy_url")"
    } >&2
  fi
  return 0
}

# Cooldown applied when the agent returns HTTP 401 (invalid / expired
# credentials). Five minutes is short enough that a user who fixes their
# credentials sees governance resume quickly, but long enough to prevent
# the tight auth-storm retry loop documented in axonflow-enterprise#2275
# (716 × 401 in 24h against /api/v1/audit/tool-call from a single source
# IP — every pre-tool-check + post-tool-audit hook fired a fresh 401
# because there was no 401-aware back-off path). Caller may override via
# AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS for testing.
_AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS="${AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS:-300}"
# Anything but whole seconds reads as the default: the value is arithmetic.
if ! [[ "$_AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS" =~ ^[0-9]{1,7}$ ]]; then
  _AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS=300
fi

# axonflow_handle_auth_failure <http_code> <body_file> <headers_file>
#   Returns 0 iff $http_code == 401. Stamps the throttle-until file with a
#   5-minute cooldown so subsequent hook fires short-circuit the network
#   call locally until the operator refreshes their credentials.
#
#   Emits a once-per-UTC-day stderr prompt directing the operator to refresh
#   credentials at the dashboard URL. The prompt is suppressed on second
#   and subsequent fires the same day (matching the envelope-prompt
#   behaviour) so the operator's terminal isn't spammed by every hook fire
#   while the throttle is active.
#
#   $body_file and $headers_file are accepted for symmetry with
#   axonflow_handle_envelope_response but are not parsed — a 401's body
#   shape is not part of any wire contract this plugin depends on.
#
#   Returns 1 for any non-401 status (including 403, 429, 5xx, network
#   failure represented as empty string). Caller's existing 403/429
#   envelope handler runs unchanged before/after this function.
axonflow_handle_auth_failure() {
  local http_code="$1"
  # body_file ($2) and headers_file ($3) intentionally unread — accepted
  # for caller-side argument-shape parity with axonflow_handle_envelope_response.

  if [ "$http_code" != "401" ]; then
    return 1
  fi

  _axonflow_ensure_cache_dir
  local deadline_epoch
  deadline_epoch=$(($(date -u +%s) + _AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS))
  echo "$deadline_epoch auth_failure" >"$_AXONFLOW_THROTTLE_FILE" 2>/dev/null

  if _axonflow_should_show_auth_prompt_today; then
    {
      echo "[AxonFlow] Authentication failed (HTTP 401) against the AxonFlow agent. Governed tool calls are blocked, and the agent is not asked again for ${_AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS} seconds, even after the credential is fixed, unless ${_AXONFLOW_THROTTLE_FILE} is deleted."
      echo "[AxonFlow] Refresh your credentials: https://getaxonflow.com/dashboard"
    } >&2
  fi
  return 0
}

# axonflow_throttle_limit_type prints the limit_type recorded with the active
# throttle stamp: "auth_failure" for the 401 pause, the envelope's limit_type
# (daily_quota, per_minute, ...) for a hosted Free-tier limit.
axonflow_throttle_limit_type() {
  awk 'NR==1 {print $2}' "$_AXONFLOW_THROTTLE_FILE" 2>/dev/null
}

# Over a hosted Free-tier limit a governed tool call is DENIED with the limit
# named and the upgrade prompt shown, not run ungoverned (ruled 2026-09-14;
# reversible by making the callers exit 0 again).
AXONFLOW_LIMIT_DENY_REASON="AxonFlow governance blocked: this AxonFlow tenant has reached its Free-tier limit, so tool calls are blocked until the limit resets. Pro removes this cap: https://getaxonflow.com/pricing/"
# axonflow_limit_deny_reason: the deny text for the limit the last envelope
# named. A request-rate limit resets; a feature or object-count limit does not
# reset with time, so its text does not say it will.
axonflow_limit_deny_reason() {
  case "${_AXONFLOW_LAST_LIMIT_TYPE:-}" in
    daily_quota|per_minute|"")
      echo "$AXONFLOW_LIMIT_DENY_REASON"
      ;;
    *)
      echo "AxonFlow governance blocked: this AxonFlow tenant has reached a Free-tier limit ($(axonflow_clean_text "$_AXONFLOW_LAST_LIMIT_TYPE")), so this tool call is blocked. Pro removes this cap: https://getaxonflow.com/pricing/"
      ;;
  esac
}
AXONFLOW_LIMIT_POST_ALERT="GOVERNANCE ALERT: AxonFlow could not check this tool output (this AxonFlow tenant has reached its Free-tier limit). Do not use or reference the output in your response until it can be checked. Pro removes this cap: https://getaxonflow.com/pricing/"

# axonflow_handle_envelope_text gives an envelope that arrived as a tool
# RESULT's text (HTTP 200) the same handling as a 429/403 body: the throttle
# stamp and the once-a-day upgrade prompt. Returns 0 when the text is an
# envelope, 1 otherwise.
axonflow_handle_envelope_text() {
  local text="$1" tmp rc
  [ -n "$text" ] || return 1
  echo "$text" | jq -e 'type == "object" and has("limit_type")' >/dev/null 2>&1 || return 1
  tmp=$(mktemp) || return 1
  printf '%s' "$text" >"$tmp"
  axonflow_handle_envelope_response "429" "$tmp" "/dev/null"
  rc=$?
  rm -f "$tmp"
  return $rc
}
