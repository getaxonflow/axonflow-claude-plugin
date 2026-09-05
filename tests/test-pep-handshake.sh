#!/usr/bin/env bash
# Unit test for the ADR-065 capability handshake
# (getaxonflow/axonflow-enterprise#3763).
#
# THIS PLUGIN HAS TWO ATTACH POINTS AND THAT IS THE RISK THIS FILE EXISTS FOR.
# The MCP session gets its headers from the `headersHelper` shell inside
# .mcp.json; every hook call builds its own headers in scripts/. A declaration
# added to only one of them is absent from the other, silently. So the central
# assertion here is not "the value is right" but "BOTH carriers produce the
# SAME bytes, and those bytes are the platform's".
#
# THE GOLDEN VECTOR IS THE POINT. This repository is public and the wire
# contract lives in a private one, so both carriers are HAND TRANSCRIPTIONS of
# a wire format - the drift class that bit five SDKs in
# axonflow-enterprise#3603. The expected string below was captured from the
# PLATFORM's own shipped encoder (contract.PEPHandshake.Encode), not
# regenerated from either carrier's output.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${PLUGIN_DIR}/scripts/pep-handshake.sh"
MCP_JSON="${PLUGIN_DIR}/.mcp.json"

GOLDEN="eyJwcm9maWxlX3ZlcnNpb24iOjEsInBlcF9pZCI6ImNsYXVkZS1jb2RlLXBsdWdpbiIsImF1ZGllbmNlIjoiYXhvbmZsb3ctZGVjaXNpb24tcHJvb2YiLCJjYXBhYmlsaXRpZXMiOltdfQ"
AUDIENCE="axonflow-decision-proof"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

# --- carrier 1: the hook script --------------------------------------------
FROM_SCRIPT=$(
  unset AXONFLOW_PEP_HANDSHAKE
  export AXONFLOW_PEP_AUDIENCE="$AUDIENCE"
  . "$SCRIPT_PATH"
  echo "${AXONFLOW_PEP_HANDSHAKE:-}"
)
if [ "$FROM_SCRIPT" = "$GOLDEN" ]; then
  pass "scripts/pep-handshake.sh matches the platform's own encoder byte for byte"
else
  fail "hook carrier disagrees with the platform encoder. got '$FROM_SCRIPT' want '$GOLDEN'"
fi

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: jq/python3 not on PATH (headersHelper assertions)"
  echo
  echo "passed: $PASS   failed: $FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

HELPER=$(python3 -c "import json;print(json.load(open('$MCP_JSON'))['mcpServers']['axonflow']['headersHelper'])")

# --- carrier 2: the .mcp.json headersHelper --------------------------------
HEADERS_SET=$(AXONFLOW_PEP_AUDIENCE="$AUDIENCE" AXONFLOW_AUTH="dGVzdDp0ZXN0" bash -c "$HELPER" 2>/dev/null)
FROM_HELPER=$(jq -r '."X-Axonflow-PEP-Handshake" // ""' <<<"$HEADERS_SET")
if [ "$FROM_HELPER" = "$GOLDEN" ]; then
  pass ".mcp.json headersHelper matches the platform's own encoder byte for byte"
else
  fail "MCP carrier disagrees with the platform encoder. got '$FROM_HELPER' want '$GOLDEN'"
fi

# --- THE ASSERTION THIS FILE EXISTS FOR ------------------------------------
# Two attach points, one contract. A declaration added to one carrier and not
# the other is absent from half this plugin's traffic, silently, and every
# other assertion here would still pass.
if [ "$FROM_SCRIPT" = "$FROM_HELPER" ] && [ -n "$FROM_SCRIPT" ]; then
  pass "both attach points present the SAME declaration"
else
  fail "the two attach points disagree: hooks='$FROM_SCRIPT' mcp='$FROM_HELPER'"
fi

# --- the decoded document ---------------------------------------------------
DOC=$(printf '%s' "$FROM_SCRIPT" | python3 -c 'import sys,base64;s=sys.stdin.read().strip();print(base64.urlsafe_b64decode(s+"="*(-len(s)%4)).decode())')
# An OMITTED capabilities member is MALFORMED to the platform and refuses the
# request; [] is the declaration "I discharge nothing". Different facts.
if [[ "$DOC" == *'"capabilities":[]'* ]]; then
  pass "an empty declaration serialises as [], never as an absent member"
else
  fail "capabilities is not an empty array: $DOC"
fi
# A PEP may declare what it CAN DO, never who it is or what it is entitled to.
if [[ "$DOC" != *'"edition"'* && "$DOC" != *'"tier"'* && "$DOC" != *'"license"'* && "$DOC" != *'"realm"'* ]]; then
  pass "no identity or entitlement member reaches the wire"
else
  fail "the document carries an identity or entitlement member: $DOC"
fi

# --- unconfigured: ABSENT, not empty, on BOTH carriers ---------------------
# A header PRESENT with an empty value is MALFORMED to the platform and
# refuses the request, which an ABSENT header does not.
UNSET_SCRIPT=$(unset AXONFLOW_PEP_HANDSHAKE AXONFLOW_PEP_AUDIENCE; . "$SCRIPT_PATH"; echo "${AXONFLOW_PEP_HANDSHAKE:-}")
if [ -z "$UNSET_SCRIPT" ]; then
  pass "an unconfigured install builds no handshake in the hook carrier"
else
  fail "expected empty, got '$UNSET_SCRIPT'"
fi

HEADERS_UNSET=$(unset AXONFLOW_PEP_AUDIENCE; AXONFLOW_AUTH="dGVzdDp0ZXN0" bash -c "$HELPER" 2>/dev/null)
if ! jq -e 'has("X-Axonflow-PEP-Handshake")' <<<"$HEADERS_UNSET" >/dev/null 2>&1; then
  pass "an unconfigured install omits the header entirely from the MCP carrier"
else
  fail "unconfigured headersHelper emitted the handshake key: $HEADERS_UNSET"
fi

# --- the MCP carrier still emits valid JSON with the handshake present -----
# The helper assembles JSON by hand with printf and a running separator; a
# missing separator produces output that parses as nothing at all.
if jq -e . >/dev/null 2>&1 <<<"$HEADERS_SET"; then
  pass "the headersHelper emits valid JSON with the handshake present"
else
  fail "the headersHelper emitted invalid JSON: $HEADERS_SET"
fi

# --- a malformed audience refuses on BOTH carriers -------------------------
for BAD in "has spaces" "-leading-hyphen"; do
  OUT=$(unset AXONFLOW_PEP_HANDSHAKE; export AXONFLOW_PEP_AUDIENCE="$BAD"; . "$SCRIPT_PATH" 2>/dev/null; echo "${AXONFLOW_PEP_HANDSHAKE:-}")
  H=$(AXONFLOW_PEP_AUDIENCE="$BAD" AXONFLOW_AUTH="dGVzdDp0ZXN0" bash -c "$HELPER" 2>/dev/null | jq -r '."X-Axonflow-PEP-Handshake" // ""')
  if [ -z "$OUT" ] && [ -z "$H" ]; then
    pass "a malformed audience builds no handshake on either carrier ('$BAD')"
  else
    fail "malformed audience '$BAD' produced hooks='$OUT' mcp='$H'; the platform would 400 every governed call"
  fi
done

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
