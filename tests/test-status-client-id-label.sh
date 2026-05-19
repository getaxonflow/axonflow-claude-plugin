#!/usr/bin/env bash
# Locks in the v1.5.0 terminology contract for /axonflow-status output:
# the user-facing label is `client_id`, NOT `tenant_id` (see CHANGELOG
# v1.5.0 and axonflow-enterprise#2230 Workstream C). Bridge note
# `(formerly tenant_id)` is allowed alongside the new label so users with
# muscle memory connect the two terms during the v9 transition.
#
# Separately asserts the on-disk JSON file CONTINUES to use the
# `tenant_id` key (file-format compat with installed base). Existing
# customer files at ~/.config/axonflow/try-registration.json must keep
# working — the rename is cosmetic, not a schema migration.
#
# Runs scripts/status.sh against an isolated $HOME with a fixture
# try-registration.json so it doesn't touch the user's real config.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATUS_SCRIPT="${PLUGIN_DIR}/scripts/status.sh"

if [ ! -x "$STATUS_SCRIPT" ] && [ ! -f "$STATUS_SCRIPT" ]; then
  echo "FAIL: $STATUS_SCRIPT missing"
  exit 1
fi

TMP_HOME=$(mktemp -d -t axonflow-status-clientid.XXXXXX)
trap 'rm -rf "$TMP_HOME"' EXIT

CONFIG_DIR="$TMP_HOME/.config/axonflow"
mkdir -p "$CONFIG_DIR"
chmod 0700 "$CONFIG_DIR"
REG_FILE="$CONFIG_DIR/try-registration.json"

# Fixture deliberately uses the LEGACY `tenant_id` JSON key — that's the
# file-format compat invariant the rename must preserve.
cat > "$REG_FILE" <<'EOF'
{
  "tenant_id": "cs_test_client_abc123",
  "secret": "fixture-secret",
  "endpoint": "https://try.getaxonflow.com"
}
EOF
chmod 0600 "$REG_FILE"

PASS=0
FAIL=0

run_status() {
  AXONFLOW_CONFIG_DIR="$CONFIG_DIR" \
  AXONFLOW_ENDPOINT="" \
  AXONFLOW_AUTH="" \
  AXONFLOW_LICENSE_TOKEN="" \
  HOME="$TMP_HOME" \
  bash "$STATUS_SCRIPT" 2>/dev/null
}

OUT=$(run_status)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  echo "FAIL: status.sh exited non-zero ($EXIT_CODE)"
  printf '%s\n' "$OUT"
  exit 1
fi

# Assertion 1: status output MUST surface the new label as a kv pair.
if printf '%s\n' "$OUT" | grep -qE '^OK  client_id=cs_test_client_abc123'; then
  echo "PASS: status output emits 'client_id=' label"
  PASS=$((PASS + 1))
else
  echo "FAIL: status output missing 'client_id=cs_test_client_abc123' line"
  printf '%s\n' "$OUT"
  FAIL=$((FAIL + 1))
fi

# Assertion 2: status output MUST NOT use the legacy `tenant_id=` label
# as a primary kv pair (the bridge note `(formerly tenant_id)` is fine —
# it's a parenthetical, not a labeled field). Match a line starting with
# `OK  tenant_id=` or `WARN tenant_id=` only.
if printf '%s\n' "$OUT" | grep -qE '^(OK|WARN) +tenant_id='; then
  echo "FAIL: status output still uses 'tenant_id=' as primary label (regression)"
  printf '%s\n' "$OUT"
  FAIL=$((FAIL + 1))
else
  echo "PASS: status output no longer uses 'tenant_id=' primary label"
  PASS=$((PASS + 1))
fi

# Assertion 3: bridge note "(formerly tenant_id)" present alongside the
# new label so v1.4.x users connect the term. Removable in v1.6.0 once
# muscle memory has migrated.
if printf '%s\n' "$OUT" | grep -qF '(formerly tenant_id)'; then
  echo "PASS: bridge note '(formerly tenant_id)' present for v1.4.x → v1.5.0 transition"
  PASS=$((PASS + 1))
else
  echo "FAIL: bridge note '(formerly tenant_id)' missing — v1.4.x users won't connect old + new term"
  printf '%s\n' "$OUT"
  FAIL=$((FAIL + 1))
fi

# Assertion 4: on-disk file format invariant — the JSON key MUST stay
# `tenant_id` (not renamed to `client_id`). Existing customer files from
# v1.4.0 must continue to be read correctly post-upgrade.
if jq -e '.tenant_id == "cs_test_client_abc123"' "$REG_FILE" >/dev/null; then
  echo "PASS: on-disk try-registration.json still uses 'tenant_id' JSON key (file-format compat)"
  PASS=$((PASS + 1))
else
  echo "FAIL: try-registration.json key shape changed — installed-base compat broken"
  FAIL=$((FAIL + 1))
fi

# Assertion 5: upgrade hint references the new label and the bridge to
# the Stripe form's still-old label.
if printf '%s\n' "$OUT" | grep -qF "Paste your client_id"; then
  echo "PASS: upgrade hint uses 'client_id' terminology"
  PASS=$((PASS + 1))
else
  echo "FAIL: upgrade hint missing 'Paste your client_id' phrasing"
  FAIL=$((FAIL + 1))
fi

echo
echo "Summary: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "client_id terminology contract intact"
exit 0
