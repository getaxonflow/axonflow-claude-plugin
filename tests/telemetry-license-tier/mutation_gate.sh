#!/usr/bin/env bash
# Mutation gate for the license_tier matrix.
#
# run.sh passing proves nothing on its own — a matrix that cannot go red is
# decoration. This gate plants a defect in a COPY of the shipped
# scripts/telemetry-ping.sh, reruns the matrix against it, and requires the
# matrix to FAIL. One mutant per property the matrix claims to protect.
#
# It also plants two mutants that MUST SURVIVE:
#
#   * an equivalent rewrite of the omission test, which changes no behaviour.
#     A gate that reports every mutant as killed cannot tell a real kill from
#     a harness that always goes red, so this is what makes the rest readable.
#   * removal of the object-type half of the extraction guard, which the source
#     documents as defence in depth rather than load-bearing. Encoding it here
#     keeps that claim honest: if the guard ever becomes observable, this
#     control starts failing and the comment is what needs updating.
#
# Two traps this is built to avoid:
#
#   * A textual patcher silently rewriting the FIRST match when the intended
#     target is the second. Every substitution below asserts it matched
#     EXACTLY ONCE and that the file actually changed; an ambiguous or
#     no-op patch fails the gate instead of producing a fake survivor.
#
#   * A mutant that does not change the OUTCOME. A neutered guard that leaves
#     behaviour identical is not a mutant, and its "survival" says nothing.
#     Each mutant below is paired with the matrix case it must break.
#
# The mutant is written into scripts/ because telemetry-ping.sh resolves
# client-header.sh, plugin.json and hooks.json relative to its own location.
# It is removed on every exit path, and the gate asserts the tree is clean
# before it reports success.
#
# Exit: 0 every mutant behaved as required · 1 a mutant survived that should
#       have been killed, or the survivor was killed · 0 + SKIP: tools absent

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
SOURCE_SCRIPT="$PLUGIN_DIR/scripts/telemetry-ping.sh"

for tool in bash curl jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not on PATH"
    exit 0
  fi
done

MUTANT="$PLUGIN_DIR/scripts/telemetry-ping.mutant.$$.sh"
cleanup() { rm -f "$PLUGIN_DIR"/scripts/telemetry-ping.mutant.*.sh; }
trap cleanup EXIT
cleanup

PASSED=0
FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL: $1" >&2; FAILED=$((FAILED + 1)); }

# apply_mutation <old> <new> — exact literal substitution, exactly once.
apply_mutation() {
  OLD="$1" NEW="$2" SRC="$SOURCE_SCRIPT" DST="$MUTANT" python3 - <<'PY'
import os, sys
old, new = os.environ["OLD"], os.environ["NEW"]
src = open(os.environ["SRC"], encoding="utf-8").read()
n = src.count(old)
if n != 1:
    print(f"AMBIGUOUS: pattern matched {n} times, expected exactly 1", file=sys.stderr)
    sys.exit(2)
out = src.replace(old, new, 1)
if out == src:
    print("NO-OP: substitution changed nothing", file=sys.stderr)
    sys.exit(3)
open(os.environ["DST"], "w", encoding="utf-8").write(out)
PY
}

# expect_mutant <killed|survives> <label> <old> <new>
expect_mutant() {
  local want="$1" label="$2" old="$3" new="$4"

  rm -f "$MUTANT"
  if ! apply_mutation "$old" "$new"; then
    fail "[$label] could not plant the mutant (pattern absent, ambiguous, or no-op)"
    return
  fi
  chmod +x "$MUTANT"

  local out rc
  out=$(bash "$HARNESS_DIR/run.sh" "$MUTANT" 2>&1)
  rc=$?
  rm -f "$MUTANT"

  if printf '%s' "$out" | grep -q '^SKIP:'; then
    fail "[$label] matrix skipped instead of running — the gate proved nothing"
    return
  fi

  if [ "$want" = "killed" ]; then
    if [ "$rc" -ne 0 ]; then
      pass "[$label] mutant killed ($(printf '%s' "$out" | grep -c '^  FAIL:') assertion(s) went red)"
    else
      fail "[$label] MUTANT SURVIVED — the matrix does not actually protect this property"
    fi
  else
    if [ "$rc" -eq 0 ]; then
      pass "[$label] neutral mutant survived — the gate can distinguish kill from noise"
    else
      fail "[$label] neutral mutant was killed — the matrix is red for a reason unrelated to behaviour"
      printf '%s\n' "$out" | grep '^  FAIL:' >&2
    fi
  fi
}

echo "--- Mutation gate: each property the matrix claims must be defensible ---"

# M1 — the field is never attached to the payload. Every round-trip case must
# go red; if any survives, the matrix is not reading the wire.
expect_mutant killed "field never sent" \
  '  + (if $license_tier == "" then {} else { license_tier: $license_tier } end)' \
  '  + {}'

# M2 — the single most important distinction in this change. Omission means
# "the plugin did not establish a tier"; "unknown" means "the platform
# answered and said it did not know". Collapsing them is a false claim, and
# every fail-open case exists to catch exactly this.
expect_mutant killed "omission replaced by a literal unknown" \
  '+ (if $license_tier == "" then {} else { license_tier: $license_tier } end)' \
  '+ (if $license_tier == "" then { license_tier: "unknown" } else { license_tier: $license_tier } end)'

# M3 — the string-type guard removed, so a numeric / boolean / structured
# tier is coerced onto the wire as though the platform had reported it.
expect_mutant killed "string-type guard removed" \
  'if type == "object" and (.[$k] | type) == "string" then .[$k] else empty end' \
  'if type == "object" then (.[$k] // empty) else empty end'

# M4 — --fail dropped, so curl hands a 4xx/5xx error body to jq and a tier
# inside it is reported as though it were an answer.
expect_mutant killed "curl --fail dropped from the health probe" \
  'curl -s --fail --max-redirs 0 --max-time 2 -H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}" "${ENDPOINT}/health"' \
  'curl -s --max-redirs 0 --max-time 2 -H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}" "${ENDPOINT}/health"'

# M5 — the length cap raised out of reach, so an endpoint-controlled string of
# arbitrary size reaches the wire.
expect_mutant killed "length cap raised out of reach" \
  'if [ "${#value}" -gt 64 ]; then' \
  'if [ "${#value}" -gt 100000 ]; then'

# M6 — client-side normalization. The plugin must relay, not interpret: a
# build that case-folds makes every tier it predates indistinguishable.
expect_mutant killed "client-side normalization introduced" \
  '  if [ "${#value}" -gt 64 ]; then' \
  '  value=$(printf "%s" "$value" | tr "[:upper:]" "[:lower:]")
  if [ "${#value}" -gt 64 ]; then'

# M7 — a second /health request. The field would then be a new data
# collection rather than a new field on an existing probe.
expect_mutant killed "second /health request introduced" \
  'LICENSE_TIER=$(relayed_health_value tier)' \
  'HEALTH_BODY=$(curl -s --fail --max-time 2 "${ENDPOINT}/health" 2>/dev/null || printf '"'"''"'"')
LICENSE_TIER=$(relayed_health_value tier)'

# M0 — the survivor, and it is planted at the EXACT site the other mutants
# attack: an equivalent rewrite of the emptiness test on the payload merge.
# Identical behaviour for every string, so the matrix must stay green. That
# is what shows the matrix is testing behaviour rather than source text — if
# this comes back killed, every "killed" above is suspect.
expect_mutant survives "equivalent rewrite of the omission test (control)" \
  'if $license_tier == "" then {} else' \
  'if ($license_tier | length) == 0 then {} else'

# M8 — the platform_version JSON splice restored. A version containing a
# double quote then yields invalid JSON, jq -n fails, PAYLOAD is empty and the
# script exits having sent NO heartbeat. This is the pre-existing defect the
# rewrite removed; the mutant proves the matrix now catches it.
expect_mutant killed "platform_version JSON splice restored" \
  '  --arg platform_version "$PLATFORM_VERSION" \' \
  '  --argjson platform_version "$(if [ -z "$PLATFORM_VERSION" ]; then printf null; else printf %s "\"$PLATFORM_VERSION\""; fi)" \'

# C2 — control, and a claim about the source kept honest. Dropping the
# `type == "object"` half of the extraction guard changes no observable
# outcome: jq errors when asked for `.tier` of an array, string or number, the
# error is swallowed, and the result is the same empty value. The half that
# earns its keep is the STRING check, which M3 above kills. If this control
# ever starts being killed, the object check has become load-bearing.
expect_mutant survives "object-type half of the extraction guard removed (control)" \
  'if type == "object" and (.[$k] | type) == "string" then .[$k] else empty end' \
  'if (.[$k] | type) == "string" then .[$k] else empty end'

# ---------------------------------------------------------------------------
# The relays added for enterprise#3662, and the two redirect properties.
# ---------------------------------------------------------------------------

# N1/N2 — each new field never attached. Their round-trip cases must go red.
expect_mutant killed "edition never sent" \
  '  + (if $edition == "" then {} else { edition: $edition } end)' \
  '  + {}'

expect_mutant killed "platform_deployment_mode never sent" \
  '  + (if $platform_deployment_mode == "" then {} else { platform_deployment_mode: $platform_deployment_mode } end)' \
  '  + {}'

# N3 — THE dangerous one. The platform's own deployment mode written over this
# plugin's local classification. The wire stays valid and the value looks
# entirely plausible; what breaks is every existing deployment_mode figure.
# Only a fixture where the two DISAGREE can catch it.
expect_mutant killed "platform mode written over the local classification" \
  '    deployment_mode: $deployment_mode,' \
  '    deployment_mode: (if $platform_deployment_mode == "" then $deployment_mode else $platform_deployment_mode end),'

# N4 — the delivery test reverted to what it was: `--fail` alone, which exits 0
# on a 3xx. The stamp then advances on a ping the receiver never processed and
# the machine goes dark for seven days. This is the defect this change fixes,
# so the matrix must be able to see it.
expect_mutant killed "any non-error response counts as delivery" \
  'case "$PING_HTTP_CODE" in
  2??)' \
  'case "$PING_HTTP_CODE" in
  ???)'

# N5/N6 — redirect following restored, one leg at a time. On /health the probe
# would read its values from a host the caller never configured; on the POST a
# redirect becomes a bodyless GET whose 200 reads as delivery.
expect_mutant killed "redirect following restored on the /health probe" \
  'curl -s --fail --max-redirs 0 --max-time 2 -H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}" "${ENDPOINT}/health"' \
  'curl -s --fail -L --max-time 2 -H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}" "${ENDPOINT}/health"'

expect_mutant killed "redirect following restored on the checkpoint POST" \
  "curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 --max-time 3 -X POST" \
  "curl -s -o /dev/null -w '%{http_code}' -L --max-time 3 -X POST"

echo ""
echo "--- Tree cleanliness ---"
LEFTOVER=$(ls "$PLUGIN_DIR"/scripts/telemetry-ping.mutant.*.sh 2>/dev/null | wc -l | tr -d ' ')
if [ "$LEFTOVER" = "0" ]; then
  pass "no mutant left in the tree"
else
  fail "$LEFTOVER mutant file(s) left behind in scripts/"
fi

echo ""
echo "========================================"
echo " telemetry relay mutation gate"
echo "========================================"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
[ "$FAILED" -eq 0 ]
