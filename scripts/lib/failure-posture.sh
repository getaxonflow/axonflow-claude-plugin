#!/usr/bin/env bash
# The failure posture both hooks read (scripts/pre-tool-check.sh and
# scripts/post-tool-audit.sh), kept in one place so the two cannot drift.
# Sourced, never executed. Each hook maps a class to its own action: the pre
# hook blocks or runs ungoverned, the post hook alerts or passes with a notice.
#
# HTTP 401 and the Free-tier envelope are settled before this table (the
# helpers in scripts/upgrade-prompt.sh). axonflow_status_class then reads the
# status of the answer that is left:
#
#   answer     2xx, or a non-2xx whose body is a JSON-RPC answer (a non-null
#              result, or an error object): read as the platform's answer
#   limit      429, whatever the body
#   refused    3xx (a redirect: the endpoint is misconfigured) and a 4xx other
#              than 408, 413 and 429, without a JSON-RPC answer
#   too_large  413 without a JSON-RPC answer (the request was bigger than the
#              agent or a proxy accepts): refused, with the size named
#   no_answer  408, 5xx and any other status without a JSON-RPC answer
#
# Within a JSON-RPC error, the code decides (axonflow_jsonrpc_error_code):
# -32603 (internal) and -32700 (parse) are no usable answer; every other code,
# and an error object without a numeric code, refused the call.

# axonflow_fail_mode_open
#   Returns 0 when AXONFLOW_FAIL_MODE is unset, empty or "open" (any case):
#   a check that got no usable answer lets the call run with a notice. Any
#   other value blocks it.
axonflow_fail_mode_open() {
  # Builtins only: a missing tr must not read "closed" as open.
  case "${AXONFLOW_FAIL_MODE:-}" in
    ""|[Oo][Pp][Ee][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

# The hook's time budget. hooks/hooks.json runs each hook with "timeout": 15,
# and a hook the host kills at its timeout answers nothing: the host treats it
# as a non-blocking error and runs the tool, so neither a block nor a notice
# arrives. Every request a hook makes therefore fits inside this budget,
# counted from the hook's own start (bash's SECONDS), with room to print the
# answer. tests/test-hooks.sh checks that it stays below the hooks.json timeout.
_AXONFLOW_HOOK_BUDGET_SECONDS=13

# axonflow_budget_timeout <configured seconds> [reserve seconds]
#   The --max-time for the next request: the configured value (a positive
#   integer; anything else counts as the given default by the caller), or the
#   budget left after holding back `reserve` seconds (default 1), whichever is
#   smaller. Prints 0 when nothing is left.
axonflow_budget_timeout() {
  local configured="$1" reserve="${2:-1}" left
  left=$(( _AXONFLOW_HOOK_BUDGET_SECONDS - SECONDS - reserve ))
  if [ "$left" -lt "$configured" ]; then
    configured=$left
  fi
  if [ "$configured" -lt 0 ]; then
    configured=0
  fi
  echo "$configured"
}

# axonflow_bootstrap_cleanup
#   Runs the registration bootstrap's EXIT cleanup (its temporary files and,
#   without flock, its try-registration.lock.d) when the bootstrap installed
#   one in this run (its marker, which the hooks clear, with any function of
#   that name from the environment, before sourcing the bootstrap). A hook that sets its own EXIT trap replaces the bootstrap's, so the
#   hook's trap calls this: a lock left behind blocks the next registration
#   for five minutes.
axonflow_bootstrap_cleanup() {
  if [ "${_AXONFLOW_BOOTSTRAP_TRAP:-}" = "1" ] && declare -F _axonflow_bootstrap_cleanup_on_exit >/dev/null 2>&1; then
    _axonflow_bootstrap_cleanup_on_exit
  fi
  return 0
}

# axonflow_clean_text <text>
#   Text that came from the network, made safe to print and to hand to the
#   model: line breaks and tabs become spaces, every other control character
#   (ESC, BEL, CR ...) is dropped, and it is trimmed and capped with cut -c 300
#   (300 characters where cut counts characters, 300 bytes where it counts
#   bytes, as GNU cut does). Bytes of multi-byte UTF-8 characters are kept.
axonflow_clean_text() {
  printf '%s' "$1" | LC_ALL=C tr '\n\t' '  ' | LC_ALL=C tr -d '\000-\037\177' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | cut -c1-300
}

# axonflow_clean_block <text>
#   Text from the network that the model reads as a block (a redacted output):
#   every ASCII control character is dropped except newline and tab, and
#   nothing is cut (trailing newlines aside, which command substitution strips),
#   since a shortened redaction would no longer be the redaction.
axonflow_clean_block() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# axonflow_result_text <json> <jq filter>
#   One field of a policy result, read with the jq filter and cleaned by
#   axonflow_clean_text. Every short field the hooks print from a result goes
#   through here, so none can skip the cleaning.
axonflow_result_text() {
  axonflow_clean_text "$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
}

# axonflow_platform_text <body>
#   The platform's own words for a refusal (a JSON-RPC error message, a coded
#   error envelope's message, or a plain {"error": "..."}), cleaned. Empty when
#   the body carries none or is not JSON.
axonflow_platform_text() {
  local raw
  raw=$(printf '%s' "$1" | jq -r 'if type == "object" then (.error.message? // (.error | strings?) // .message? // empty) else empty end' 2>/dev/null)
  axonflow_clean_text "$raw"
}

# axonflow_is_jsonrpc_answer <body>
#   Prints "true" when the body is ONE JSON-RPC answer: a single JSON document,
#   an object carrying "jsonrpc" and either a non-null result or an error
#   object. A null result or error, an error that is not an object, and a body
#   of more than one document are not an answer.
axonflow_is_jsonrpc_answer() {
  local out
  out=$(printf '%s' "$1" | jq -rs 'if length == 1 and (.[0] | type) == "object" and (.[0] | has("jsonrpc")) and ((.[0].result != null) or ((.[0].error | type) == "object")) then "true" else "false" end' 2>/dev/null)
  if [ "$out" = "true" ]; then echo true; else echo false; fi
}

# axonflow_jsonrpc_error_code <body>
#   The code of the body's JSON-RPC error object, "none" when that object has
#   no numeric code, and empty when the body has no error object or is more
#   than one JSON document (read the same way as axonflow_is_jsonrpc_answer).
axonflow_jsonrpc_error_code() {
  printf '%s' "$1" | jq -rs 'if length == 1 and (.[0] | type) == "object" and ((.[0].error | type) == "object") then (if (.[0].error.code | type) == "number" then (.[0].error.code | tostring) else "none" end) else empty end' 2>/dev/null
}

# axonflow_one_json_document <body>
#   Returns 0 when the body is exactly one JSON document. Each hook checks this
#   right after the empty-body check: the two helpers above read a body of two
#   documents as no answer and no error, while the result readers after them
#   would take the allow from one document and ignore an error in the other.
#   Anything but one document (two or more, or not JSON) is no usable answer.
axonflow_one_json_document() {
  [ "$(printf '%s' "$1" | jq -s 'length' 2>/dev/null)" = "1" ]
}

# axonflow_status_class <http_code> <is_jsonrpc_answer>
#   Prints the row of the table above.
axonflow_status_class() {
  local code="$1" jsonrpc="$2"
  case "$code" in
    429) echo limit; return ;;
    2??) echo answer; return ;;
  esac
  if [ "$jsonrpc" = "true" ]; then
    echo answer
    return
  fi
  case "$code" in
    3??) echo refused ;;
    408) echo no_answer ;;
    413) echo too_large ;;
    4??) echo refused ;;
    *) echo no_answer ;;
  esac
}
