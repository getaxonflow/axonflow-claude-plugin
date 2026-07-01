#!/usr/bin/env bash
# Per-developer identity resolution for governed AxonFlow requests — issue #2754.
#
# Sourced by the hooks (pre-tool-check.sh, post-tool-audit.sh) and the headers
# reference impl (mcp-auth-headers.sh) — never invoked. After sourcing and
# calling resolve_user_identity, AXONFLOW_USER_EMAIL_RESOLVED is exported with
# the resolved developer email (empty when no identity is available).
#
# The plugin sends this as the X-User-Email header on every governed agent
# request so the platform can attribute the audit row to a real person. Without
# it the agent falls back to a synthetic client-scoped id ("mcp-client:<org>")
# and the customer-portal User column shows N/A — the exact bug #2754 fixes.
#
# Resolution order (canonical — must not change without a CHANGELOG entry):
#
#   1. AXONFLOW_USER_EMAIL env var — the SUPPORTED source. Claude Code does not
#      expose the logged-in Anthropic account email to hooks/plugins, so a fleet
#      sets this per developer via MDM / shell profile (epic issue I / #2762).
#   2. `git config user.email` — BEST-EFFORT last resort only. This is the git
#      identity, NOT the Anthropic account, so it can be silently wrong (shared
#      machine, service account, or simply unset). Used only when the env var is
#      absent, and clearly documented as such in the README.
#   3. Unset — no X-User-Email header is sent (the caller omits it entirely
#      rather than shipping an empty header). The agent then degrades to its
#      client-scoped synthetic id, never a hard NULL.
#
# Never exits non-zero. Never blocks the calling hook.

# _sanitize_user_email strips characters a valid email never contains but which
# could break a downstream sink: all whitespace (space/tab/CR/LF) defuses HTTP
# header-splitting, and the double-quote + backslash are removed so the value is
# safe to interpolate into the .mcp.json headersHelper's JSON output without
# escaping. Lossless for real addresses.
_sanitize_user_email() {
  printf '%s' "$1" | tr -d ' \t\r\n"\\'
}

# resolve_user_identity — side-effect only. Leaves AXONFLOW_USER_EMAIL_RESOLVED
# exported (possibly empty) when it returns.
resolve_user_identity() {
  local email=""
  if [ -n "${AXONFLOW_USER_EMAIL:-}" ]; then
    email="$AXONFLOW_USER_EMAIL"
  elif command -v git >/dev/null 2>&1; then
    # Best-effort git fallback — NOT the Anthropic account email. Never fails
    # the hook: an unset git identity just yields an empty string.
    email="$(git config user.email 2>/dev/null || true)"
  fi
  AXONFLOW_USER_EMAIL_RESOLVED="$(_sanitize_user_email "$email")"
  export AXONFLOW_USER_EMAIL_RESOLVED
}
