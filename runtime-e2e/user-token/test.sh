#!/usr/bin/env bash
# Claude Code runtime E2E: per-user authorization token OUTCOME test
# (axonflow-enterprise#2935, epic #2919).
#
# Drives the plugin's REAL hook scripts (pre-tool-check.sh + post-tool-audit.sh)
# — the runtime components that attach X-User-Token on every governed tool call
# — against a LIVE AxonFlow agent (no mocks), then asserts the resulting
# canonical `audit_logs` rows attribute to the token's VALIDATED identity, and
# that a tampered token fails CLOSED with a structured deny.
#
# Legs:
#   0. Unconfigured (the common fleet state today): no token anywhere → rows
#      attribute via the X-User-Email label exactly as pre-1.10 (additive-only
#      proof against ANY platform version).
#   1. Validated identity (needs a platform with enterprise#2929+): a real
#      minted token → rows on BOTH planes attribute to the token's canonical
#      email even though AXONFLOW_USER_EMAIL asserts a DIFFERENT address —
#      the validated identity beats the forgeable label.
#   2. Unhappy path: a tampered token → the platform rejects (401/-32001) and
#      pre-tool-check.sh emits a structured DENY naming the per-user token as
#      a likely cause. No silent fall-open on a bad credential.
#
# Capability probe: pre-#2929 platforms IGNORE X-User-Token. The harness sends
# a garbage token on a bare tools/list request — acceptance means legs 1-2
# cannot run (SKIP with a notice), rejection means the platform validates.
#
# Enterprise auth (cite feedback-runtime-e2e-must-support-enterprise-auth): the
# harness reads AXONFLOW_AUTH / AXONFLOW_E2E_ENTERPRISE_AUTH (Basic) so it works
# against a real in-VPC Enterprise agent.
#
# Prereqs (skips cleanly otherwise): see README.md next to this file.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"
POST_HOOK="$PLUGIN_DIR/scripts/post-tool-audit.sh"

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"

for bin in jq curl psql python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "SKIP: $bin not on PATH"; exit 0; }
done
if ! curl -sSf -o /dev/null --max-time 5 "$ENDPOINT/health"; then
  echo "SKIP: AxonFlow agent not reachable at $ENDPOINT/health"
  exit 0
fi

# Resolve enterprise Basic auth (support all three env shapes).
AUTH="${AXONFLOW_AUTH:-}"
if [ -z "$AUTH" ] && [ -n "${AXONFLOW_E2E_ENTERPRISE_AUTH:-}" ]; then
  AUTH="$AXONFLOW_E2E_ENTERPRISE_AUTH"
fi
if [ -z "$AUTH" ] && [ -n "${AXONFLOW_E2E_ORG_ID:-}" ] && [ -n "${AXONFLOW_E2E_LICENSE_KEY:-}" ]; then
  AUTH="$(printf '%s:%s' "$AXONFLOW_E2E_ORG_ID" "$AXONFLOW_E2E_LICENSE_KEY" | base64 | tr -d '\n')"
fi
if [ -z "$AUTH" ]; then
  echo "SKIP: no agent credential (set AXONFLOW_AUTH / AXONFLOW_E2E_ENTERPRISE_AUTH / AXONFLOW_E2E_ORG_ID+LICENSE_KEY)"
  exit 0
fi
DB_URL="${AXONFLOW_E2E_DB_URL:-}"
if [ -z "$DB_URL" ]; then
  echo "SKIP: AXONFLOW_E2E_DB_URL not set (needed to read back audit_logs attribution)"
  exit 0
fi

query() { psql "$DB_URL" -tAc "$1" 2>/dev/null; }

# wait_count <count-sql> <min> — poll (1s interval, up to 20s) until the
# scalar count query returns >= min (audit writers are async).
wait_count() {
  local sql="$1" min="$2" n=0 c=0
  while [ "$n" -lt 20 ]; do
    c=$(query "$sql")
    c="${c:-0}"
    [ "$c" -ge "$min" ] && break
    n=$((n + 1))
    sleep 1
  done
  printf '%s' "$c"
}

export AXONFLOW_ENDPOINT="$ENDPOINT"
export AXONFLOW_AUTH="$AUTH"
export AXONFLOW_TELEMETRY=off

errors=0

# ---------------------------------------------------------------------------
# Leg 0 — UNCONFIGURED (the common fleet state): no token env, no token file
# (fresh HOME). Attribution must work exactly as pre-1.10: the label path.
# ---------------------------------------------------------------------------
EMAIL0="e2e-notoken-$(date +%s)-$RANDOM@example.com"
SID0="e2e-notoken-sess-$(date +%s)-$RANDOM"
HOME0="$(mktemp -d)"
echo "--- Leg 0: unconfigured (label attribution, developer=$EMAIL0) ---"
echo "{\"session_id\":\"$SID0\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf / --no-preserve-root\"}}" \
  | env -u AXONFLOW_USER_TOKEN HOME="$HOME0" AXONFLOW_USER_EMAIL="$EMAIL0" "$PRE_HOOK" >/dev/null 2>&1
echo "{\"session_id\":\"$SID0\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"tool_response\":{\"stdout\":\"hi\",\"exitCode\":0}}" \
  | env -u AXONFLOW_USER_TOKEN HOME="$HOME0" AXONFLOW_USER_EMAIL="$EMAIL0" "$POST_HOOK" >/dev/null 2>&1
ROWS0=$(wait_count "SELECT count(*) FROM audit_logs WHERE session_id='$SID0';" 2)
if [ "${ROWS0:-0}" -ge 2 ]; then
  echo "PASS: unconfigured plugin — governed rows written on both planes (no behavior change)"
else
  echo "FAIL: unconfigured plugin wrote ${ROWS0:-0} rows for session_id=$SID0 (expected >=2)"
  errors=$((errors + 1))
fi
rm -rf "$HOME0"

# ---------------------------------------------------------------------------
# Capability probe: does this platform VALIDATE X-User-Token? (enterprise#2929)
# A garbage token on a bare tools/list: pre-#2929 ignores the header (HTTP
# 200), post-#2929 enterprise rejects it (HTTP 401, -32001).
# ---------------------------------------------------------------------------
PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -X POST "$ENDPOINT/api/v1/mcp-server" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "Authorization: Basic $AUTH" \
  -H "X-User-Token: e2e-garbage-token-probe" \
  -d '{"jsonrpc":"2.0","id":"probe","method":"tools/list"}')
if [ "$PROBE_CODE" != "401" ]; then
  echo "SKIP: platform at $ENDPOINT does not validate X-User-Token yet (probe HTTP $PROBE_CODE; needs enterprise#2929+) — legs 1-2 skipped."
  echo ""
  if [ "$errors" -ne 0 ]; then echo "FAILED: $errors error(s)"; exit 1; fi
  echo "user-token runtime E2E: leg 0 passed (legs 1-2 skipped: platform pre-#2929)"
  exit 0
fi
echo "--- Platform validates X-User-Token (probe HTTP 401) — running token legs ---"

# ---------------------------------------------------------------------------
# Resolve a REAL minted token: operator-supplied, else sign one with the
# agent's JWT_SECRET using the exact mint-API claims contract
# (platform/shared/identity: iss=axonflow-user-token-mint, email, role,
# org_id, jti, iat, exp). The platform performs its full validation
# (signature, issuer, expiry, org binding, revocation) — nothing is stubbed.
# ---------------------------------------------------------------------------
TOKEN="${AXONFLOW_E2E_USER_TOKEN:-}"
TOKEN_EMAIL="${AXONFLOW_E2E_USER_TOKEN_EMAIL:-}"
if [ -z "$TOKEN" ]; then
  if [ -z "${AXONFLOW_E2E_JWT_SECRET:-}" ] || [ -z "${AXONFLOW_E2E_ORG_ID:-}" ]; then
    echo "SKIP: no minted token (set AXONFLOW_E2E_USER_TOKEN+AXONFLOW_E2E_USER_TOKEN_EMAIL, or AXONFLOW_E2E_JWT_SECRET+AXONFLOW_E2E_ORG_ID) — legs 1-2 skipped."
    if [ "$errors" -ne 0 ]; then echo "FAILED: $errors error(s)"; exit 1; fi
    exit 0
  fi
  TOKEN_EMAIL="e2e-token-dev-$(date +%s)-$RANDOM@example.com"
  TOKEN=$(TOKEN_EMAIL="$TOKEN_EMAIL" ORG_ID="$AXONFLOW_E2E_ORG_ID" JWT_SECRET="$AXONFLOW_E2E_JWT_SECRET" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time, uuid
def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
header = {"alg": "HS256", "typ": "JWT"}
now = int(time.time())
claims = {
    "iss": "axonflow-user-token-mint",
    "email": os.environ["TOKEN_EMAIL"],
    "role": "developer",
    "org_id": os.environ["ORG_ID"],
    "jti": str(uuid.uuid4()),
    "iat": now,
    "exp": now + 3600,
}
signing_input = b64url(json.dumps(header, separators=(",", ":")).encode()) + "." + \
    b64url(json.dumps(claims, separators=(",", ":")).encode())
sig = hmac.new(os.environ["JWT_SECRET"].encode(), signing_input.encode(), hashlib.sha256).digest()
print(signing_input + "." + b64url(sig))
PY
)
  if [ -z "$TOKEN" ]; then
    echo "FAIL: could not sign a mint-contract token"
    exit 1
  fi
fi
if [ -z "$TOKEN_EMAIL" ]; then
  echo "SKIP: AXONFLOW_E2E_USER_TOKEN set without AXONFLOW_E2E_USER_TOKEN_EMAIL (needed for the attribution assertion) — legs 1-2 skipped."
  if [ "$errors" -ne 0 ]; then echo "FAILED: $errors error(s)"; exit 1; fi
  exit 0
fi
# The validator canonicalizes (lowercase+trim) the email — assert on that.
TOKEN_EMAIL_CANON=$(printf '%s' "$TOKEN_EMAIL" | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------------------
# Leg 1 — VALIDATED IDENTITY beats the forgeable label. AXONFLOW_USER_EMAIL
# deliberately asserts a DIFFERENT address; the audit rows must carry the
# token's canonical email on BOTH planes. Env leg for the pre-tool plane,
# 0600-file leg for the post-tool plane — covering both resolution sources
# against the live stack.
# ---------------------------------------------------------------------------
FORGED="forged-label-$(date +%s)@example.com"
SID1="e2e-token-sess-$(date +%s)-$RANDOM"
HOME1="$(mktemp -d)"
echo "--- Leg 1: validated identity (token=$TOKEN_EMAIL_CANON, forged label=$FORGED) ---"
echo "{\"session_id\":\"$SID1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf / --no-preserve-root\"}}" \
  | env HOME="$HOME1" AXONFLOW_USER_EMAIL="$FORGED" AXONFLOW_USER_TOKEN="$TOKEN" "$PRE_HOOK" >/dev/null 2>&1

mkdir -p "$HOME1/.config/axonflow"
printf '{"token":"%s"}' "$TOKEN" > "$HOME1/.config/axonflow/user-token.json"
chmod 600 "$HOME1/.config/axonflow/user-token.json"
echo "{\"session_id\":\"$SID1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"tool_response\":{\"stdout\":\"hi\",\"exitCode\":0}}" \
  | env -u AXONFLOW_USER_TOKEN HOME="$HOME1" AXONFLOW_USER_EMAIL="$FORGED" "$POST_HOOK" >/dev/null 2>&1

CHK1=$(wait_count "SELECT count(*) FROM audit_logs WHERE request_type='mcp_check_policy' AND user_email='$TOKEN_EMAIL_CANON' AND session_id='$SID1';" 1)
if [ "${CHK1:-0}" -ge 1 ]; then
  echo "PASS: check_policy row attributes to the token's validated email (env leg)"
else
  echo "FAIL: no mcp_check_policy row with user_email=$TOKEN_EMAIL_CANON session_id=$SID1"
  errors=$((errors + 1))
fi
AUD1=$(wait_count "SELECT count(*) FROM audit_logs WHERE request_type='tool_call_audit' AND user_email='$TOKEN_EMAIL_CANON' AND session_id='$SID1';" 1)
if [ "${AUD1:-0}" -ge 1 ]; then
  echo "PASS: audit_tool_call row attributes to the token's validated email (0600-file leg)"
else
  echo "FAIL: no tool_call_audit row with user_email=$TOKEN_EMAIL_CANON session_id=$SID1"
  errors=$((errors + 1))
fi
FORGED_ROWS=$(query "SELECT count(*) FROM audit_logs WHERE session_id='$SID1' AND user_email='$FORGED';")
if [ "${FORGED_ROWS:-0}" -eq 0 ]; then
  echo "PASS: the forged X-User-Email label attributed ZERO rows while the token was present"
else
  echo "FAIL: $FORGED_ROWS row(s) attributed to the forged label $FORGED despite a valid token"
  errors=$((errors + 1))
fi
echo "--- audit_logs rows for leg 1 ---"
query "SELECT request_type, policy_decision, user_email, session_id FROM audit_logs WHERE session_id='$SID1' ORDER BY timestamp;" || true
rm -rf "$HOME1"

# ---------------------------------------------------------------------------
# Leg 2 — UNHAPPY PATH: a tampered token (bit-flipped signature) must fail
# CLOSED: pre-tool-check.sh emits a structured deny whose reason names the
# per-user token, and the tool call is blocked — never silently ungoverned.
# ---------------------------------------------------------------------------
# Bit-flip the last signature character; pick a replacement that differs from
# the original so the tamper is guaranteed even when the token ends in "x".
case "$TOKEN" in
  *x) TAMPERED="${TOKEN%?}A" ;;
  *)  TAMPERED="${TOKEN%?}x" ;;
esac
SID2="e2e-tampered-sess-$(date +%s)-$RANDOM"
HOME2="$(mktemp -d)"
echo "--- Leg 2: tampered token fail-closed ---"
DECISION=$(echo "{\"session_id\":\"$SID2\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo benign\"}}" \
  | env HOME="$HOME2" AXONFLOW_USER_EMAIL="$TOKEN_EMAIL" AXONFLOW_USER_TOKEN="$TAMPERED" "$PRE_HOOK" 2>/dev/null)
rm -rf "$HOME2"
if [ "$(printf '%s' "$DECISION" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = "deny" ]; then
  echo "PASS: tampered token → structured deny (fail-closed, no silent fall-open)"
else
  echo "FAIL: tampered token did not produce a deny: $DECISION"
  errors=$((errors + 1))
fi
if printf '%s' "$DECISION" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null | grep -q "per-user token"; then
  echo "PASS: deny reason names the per-user token as a likely cause"
else
  echo "FAIL: deny reason does not mention the per-user token"
  errors=$((errors + 1))
fi
if printf '%s' "$DECISION" | grep -qF "$TAMPERED"; then
  echo "FAIL: deny output leaked the token value"
  errors=$((errors + 1))
else
  echo "PASS: deny output does not leak the token value"
fi

echo ""
if [ "$errors" -ne 0 ]; then
  echo "FAILED: $errors error(s)"
  exit 1
fi
echo "user-token runtime E2E: ALL legs passed"
exit 0
