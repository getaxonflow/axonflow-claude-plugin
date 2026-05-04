#!/usr/bin/env bash
# Claude Code runtime E2E: free-tier email-recovery flow via the
# /axonflow-recover and /axonflow-recover-verify slash commands.
#
# Asserts the plugin's slash-command implementations (recover.sh and
# recover-verify.sh) drive the platform recovery flow end-to-end:
#
#   1. recover.sh hits /api/v1/recover with the user's email and gets
#      the platform's 202 anti-enumeration response.
#   2. recover-verify.sh consumes the magic-link token (out-of-band) and
#      writes fresh tenant credentials to ~/.config/axonflow/try-registration.json.
#   3. The persisted file has 0600 perms inside a 0700 directory and
#      contains the {tenant_id, secret, secret_prefix, expires_at, endpoint,
#      email, note} bundle that came back from the platform.
#
# This is the runtime-path test the V1 wire-up PR ships with. Per
# axonflow-internal-docs/engineering/FEATURE_RUNTIME_COVERAGE.md every
# user-facing feature gets a test that exercises the real HTTP flow
# against a live agent + DB.
#
# Required env (gracefully SKIPs when missing — this test never breaks
# CI on a developer machine without a stack):
#
#   AGENT_URL                              — live agent URL (default localhost:8080)
#   AXONFLOW_RECOVERY_TEST_CAPTURE_FILE   — path the agent's noop email
#                                            sender appends `to=<email>
#                                            link=...?token=<hex>` lines
#                                            to. MUST be set on the agent
#                                            container too. See
#                                            axonflow-enterprise/runtime-e2e/recovery/README.md
#                                            for the docker-compose overlay.
#   TEST_EMAIL                             — optional override; default is
#                                            uniquely generated per run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

AGENT_URL="${AGENT_URL:-http://localhost:8080}"
RECOVER_SH="${PLUGIN_DIR}/scripts/recover.sh"
RECOVER_VERIFY_SH="${PLUGIN_DIR}/scripts/recover-verify.sh"
CAPTURE_FILE="${AXONFLOW_RECOVERY_TEST_CAPTURE_FILE:-/tmp/axonflow-recovery-captures.txt}"
TEST_EMAIL="${TEST_EMAIL:-claude-plugin-recovery-runtime-$$-$(date +%s)@axonflow-test.invalid}"

for f in "$RECOVER_SH" "$RECOVER_VERIFY_SH"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required script missing: $f"
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "SKIP: curl not on PATH"
  exit 0
fi

# Live-stack sanity: skip cleanly if agent unreachable so this test is
# safe to run on any developer laptop / CI runner without a stack.
# Both /health AND /api/v1/register must respond like AxonFlow agent for
# us to proceed — a different service on :8080 must not look like a pass.
if ! curl -sSf -o /dev/null --max-time 5 "$AGENT_URL/health" 2>/dev/null; then
  echo "SKIP: AxonFlow agent not reachable at $AGENT_URL/health"
  echo "      Start one via axonflow-enterprise scripts/setup-e2e-testing.sh"
  echo "      with the recovery overlay (see axonflow-enterprise/runtime-e2e/recovery/README.md)."
  exit 0
fi
# Probe-shape check: a real AxonFlow agent returns JSON (4xx for empty
# body) on /api/v1/register, not 404. Skip if it's some other service on
# the port.
PROBE_CT=$(curl -sS -o /dev/null --max-time 5 -w "%{http_code} %{content_type}" \
  -X POST "$AGENT_URL/api/v1/register" \
  -H "Content-Type: application/json" \
  -d '{}' 2>/dev/null || echo "000 ")
case "$PROBE_CT" in
  *application/json*) ;;
  *)
    echo "SKIP: $AGENT_URL responds to /health but /api/v1/register is not JSON ($PROBE_CT)."
    echo "      A different service appears to be listening on this port; not the AxonFlow agent."
    echo "      Start the agent via axonflow-enterprise scripts/setup-e2e-testing.sh."
    exit 0
    ;;
esac

# Stash and restore any pre-existing try-registration.json so the test
# doesn't trash the developer's own credentials.
EXISTING_REG="${HOME}/.config/axonflow/try-registration.json"
RESTORE_REG=""
if [ -f "$EXISTING_REG" ]; then
  RESTORE_REG=$(mktemp -t axonflow-runtime-recovery-restore.XXXXXX)
  cp -p "$EXISTING_REG" "$RESTORE_REG"
fi

cleanup() {
  if [ -n "$RESTORE_REG" ] && [ -f "$RESTORE_REG" ]; then
    cp -p "$RESTORE_REG" "$EXISTING_REG" 2>/dev/null || true
    rm -f "$RESTORE_REG"
  else
    # No prior file → leave none behind from this run.
    rm -f "$EXISTING_REG"
  fi
}
trap cleanup EXIT

errors=0

echo "=== runtime-e2e: recovery slash-command flow ==="
echo "Agent URL:    $AGENT_URL"
echo "Capture file: $CAPTURE_FILE"
echo "Test email:   $TEST_EMAIL"
echo ""

# -----------------------------------------------------------------------------
# Step 1: register a fresh community-saas tenant bound to TEST_EMAIL so we
# have something to recover. Uses the agent's /api/v1/register endpoint
# directly (the plugin doesn't expose registration as a slash command;
# the Community-SaaS bootstrap handles it on first hook fire).
# -----------------------------------------------------------------------------
echo "Step 1: register a tenant bound to TEST_EMAIL"
REG_BODY=$(jq -n --arg label "claude-plugin-recovery-test" --arg email "$TEST_EMAIL" '{label: $label, email: $email}')
REG_RESP=$(curl -sS --max-time 10 -X POST "$AGENT_URL/api/v1/register" \
  -H "Content-Type: application/json" \
  -d "$REG_BODY" 2>/dev/null)
ORIG_TENANT=$(echo "$REG_RESP" | jq -r '.tenant_id // empty' 2>/dev/null)
if [ -z "$ORIG_TENANT" ]; then
  echo "  FAIL: registration did not return a tenant_id"
  echo "        body: $REG_RESP"
  errors=$((errors + 1))
else
  echo "  PASS: original tenant_id = $ORIG_TENANT (bound to $TEST_EMAIL)"
fi

# Reset capture file so we only see THIS run's email.
: >"$CAPTURE_FILE" 2>/dev/null || {
  echo "  SKIP: cannot write to $CAPTURE_FILE — must be writable by the agent container too"
  echo "        (set AXONFLOW_RECOVERY_TEST_CAPTURE_FILE on the agent and mount the path)"
  exit 0
}

# -----------------------------------------------------------------------------
# Step 2: run /axonflow-recover via the helper script and assert it writes
# an `OK 202 …` line and the platform actually issued a magic link.
# -----------------------------------------------------------------------------
echo ""
echo "Step 2: /axonflow-recover (via recover.sh) → 202 + magic link sent"
RECOVER_OUT=$(AXONFLOW_ENDPOINT="$AGENT_URL" "$RECOVER_SH" "$TEST_EMAIL" 2>&1)
RECOVER_CODE=$?
if [ "$RECOVER_CODE" -ne 0 ]; then
  echo "  FAIL: recover.sh exited $RECOVER_CODE"
  echo "        output: $RECOVER_OUT"
  errors=$((errors + 1))
elif ! echo "$RECOVER_OUT" | grep -q '^OK   202'; then
  echo "  FAIL: recover.sh did not emit OK 202 line"
  echo "        output: $RECOVER_OUT"
  errors=$((errors + 1))
else
  echo "  PASS: recover.sh got 202 from $AGENT_URL/api/v1/recover"
fi

# Wait briefly for the noop sender to flush.
for _ in 1 2 3 4 5; do
  if [ -s "$CAPTURE_FILE" ] && grep -q "to=$TEST_EMAIL" "$CAPTURE_FILE"; then
    break
  fi
  sleep 0.5
done

if ! grep -q "to=$TEST_EMAIL" "$CAPTURE_FILE"; then
  echo "  FAIL: no captured magic link for $TEST_EMAIL after 2.5s"
  echo "        capture file: $(cat "$CAPTURE_FILE" 2>/dev/null | head -3)"
  echo "        likely cause: agent container doesn't have AXONFLOW_RECOVERY_TEST_CAPTURE_FILE"
  errors=$((errors + 1))
  TOKEN=""
else
  TOKEN=$(grep "to=$TEST_EMAIL" "$CAPTURE_FILE" | tail -1 | sed 's|.*token=||')
  if [ -z "$TOKEN" ] || [ "${#TOKEN}" -lt 32 ]; then
    echo "  FAIL: extracted token looks malformed (length=${#TOKEN})"
    errors=$((errors + 1))
    TOKEN=""
  else
    echo "  PASS: extracted magic-link token (length=${#TOKEN})"
  fi
fi

# -----------------------------------------------------------------------------
# Step 3: run /axonflow-recover-verify via the helper script and assert it
# writes fresh credentials to ~/.config/axonflow/try-registration.json with
# 0600 perms.
# -----------------------------------------------------------------------------
if [ -n "$TOKEN" ]; then
  echo ""
  echo "Step 3: /axonflow-recover-verify (via recover-verify.sh) → fresh creds persisted"
  # Pre-step: remove any existing reg file so the test asserts the verify
  # script created it.
  rm -f "$EXISTING_REG" 2>/dev/null || true

  VERIFY_OUT=$(AXONFLOW_ENDPOINT="$AGENT_URL" "$RECOVER_VERIFY_SH" "$TOKEN" 2>&1)
  VERIFY_CODE=$?
  if [ "$VERIFY_CODE" -ne 0 ]; then
    echo "  FAIL: recover-verify.sh exited $VERIFY_CODE"
    echo "        output: $VERIFY_OUT"
    errors=$((errors + 1))
  elif ! echo "$VERIFY_OUT" | grep -q '^OK   tenant_id='; then
    echo "  FAIL: recover-verify.sh did not emit OK tenant_id= line"
    echo "        output: $VERIFY_OUT"
    errors=$((errors + 1))
  else
    NEW_TENANT=$(echo "$VERIFY_OUT" | grep -oE 'tenant_id=[^ ]+' | head -1 | cut -d= -f2)
    echo "  PASS: recover-verify.sh got new tenant_id=$NEW_TENANT"
    if [ "$NEW_TENANT" = "$ORIG_TENANT" ]; then
      echo "  FAIL: new tenant_id matches original ($ORIG_TENANT) — recovery should mint a fresh tenant"
      errors=$((errors + 1))
    fi

    # Assert the file was persisted with 0600 perms inside 0700 dir.
    if [ ! -f "$EXISTING_REG" ]; then
      echo "  FAIL: recover-verify.sh did not write $EXISTING_REG"
      errors=$((errors + 1))
    else
      MODE=$(stat -c %a "$EXISTING_REG" 2>/dev/null || stat -f %Lp "$EXISTING_REG" 2>/dev/null)
      if [ "$MODE" != "600" ] && [ "$MODE" != "0600" ]; then
        echo "  FAIL: persisted file has unsafe mode $MODE (expected 600)"
        errors=$((errors + 1))
      else
        echo "  PASS: persisted file has mode 0600"
      fi
      DIR_MODE=$(stat -c %a "${HOME}/.config/axonflow" 2>/dev/null || stat -f %Lp "${HOME}/.config/axonflow" 2>/dev/null)
      if [ "$DIR_MODE" != "700" ] && [ "$DIR_MODE" != "0700" ]; then
        echo "  FAIL: ~/.config/axonflow has mode $DIR_MODE (expected 700)"
        errors=$((errors + 1))
      else
        echo "  PASS: ~/.config/axonflow has mode 0700"
      fi
      # Validate persisted bundle shape.
      for field in tenant_id secret secret_prefix expires_at endpoint email; do
        VAL=$(jq -r --arg f "$field" '.[$f] // empty' "$EXISTING_REG" 2>/dev/null)
        if [ -z "$VAL" ]; then
          echo "  FAIL: persisted file missing required field: $field"
          errors=$((errors + 1))
        fi
      done
      PERSISTED_EMAIL=$(jq -r '.email // empty' "$EXISTING_REG" 2>/dev/null)
      if [ "$PERSISTED_EMAIL" != "$TEST_EMAIL" ]; then
        echo "  FAIL: persisted email '$PERSISTED_EMAIL' != expected '$TEST_EMAIL'"
        errors=$((errors + 1))
      else
        echo "  PASS: persisted email matches input ($TEST_EMAIL)"
      fi
    fi

    # Step 4: replay rejected (consumed-once invariant) — script must
    # exit non-zero with HTTP 401 surfaced.
    echo ""
    echo "Step 4: replay token → recover-verify.sh exits non-zero (HTTP 401)"
    REPLAY_OUT=$(AXONFLOW_ENDPOINT="$AGENT_URL" "$RECOVER_VERIFY_SH" "$TOKEN" 2>&1)
    REPLAY_CODE=$?
    if [ "$REPLAY_CODE" -eq 0 ]; then
      echo "  FAIL: replay should have failed but exit code was 0"
      errors=$((errors + 1))
    elif ! echo "$REPLAY_OUT" | grep -q "ERR  401"; then
      echo "  FAIL: replay should surface ERR 401 from the platform"
      echo "        output: $REPLAY_OUT"
      errors=$((errors + 1))
    else
      echo "  PASS: replay rejected with ERR 401 (consumed-once invariant holds)"
    fi
  fi
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors recovery-flow assertion(s) failed"
  exit 1
fi

echo ""
echo "PASS: recovery slash-command flow verified end-to-end (recover → magic link → recover-verify → persisted creds → replay rejected)"
