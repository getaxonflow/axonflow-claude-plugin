#!/usr/bin/env bash
# Build the ADR-065 PEP capability handshake header value.
#
# getaxonflow/axonflow-enterprise#3763.
#
# The plugin tells the platform WHAT IT CAN DISCHARGE, on every governed call,
# as a base64url-encoded JSON document in X-Axonflow-PEP-Handshake. A platform
# that would attach a mandatory obligation this plugin has declared it cannot
# carry out DENIES the request, rather than handing the content over and
# trusting the plugin to cope (ADR-065 invariant 8).
#
# OPT-IN. Sets AXONFLOW_PEP_HANDSHAKE only when AXONFLOW_PEP_AUDIENCE is set.
# Unset leaves the variable EMPTY and every call site omits the header, which is
# byte-for-byte the pre-handshake behaviour.
#
# WHY AN EMPTY VALUE IS NEVER SENT. A header that is PRESENT with an empty value
# is MALFORMED to the platform and refuses the request, which an ABSENT header
# does not. So every consumer of this variable must test it before setting the
# header; a call site that interpolates it unconditionally turns every
# unconfigured install into a 400.
#
# WHY THIS PLUGIN DECLARES NO CAPABILITIES. A field_redact obligation is
# discharged by substituting the platform's engine-masked text for the original,
# and ADR-056 forbids a client from redacting for itself. This plugin's shell
# call sites POST a statement and report the verdict; they perform no
# substitution, so the plugin cannot ESTABLISH that the obligation would be
# discharged. A declaration describes what an enforcement point CAN do rather
# than what it should do, so it declares the empty set and the platform refuses
# rather than allowing on the strength of a substitution nobody performs.
#
# WHY THIS RE-IMPLEMENTS AN ENCODER THAT EXISTS. The canonical encoder is
# contract.PEPHandshake.Encode in a PRIVATE repository this public one cannot
# import, so this is a hand transcription of a wire format - the drift class
# that bit five SDKs in axonflow-enterprise#3603. The test asserts the exact
# bytes against a vector captured from the platform's own shipped encoder.
#
# Idempotent: sourcing again is a no-op once AXONFLOW_PEP_HANDSHAKE is set.

if [ -z "${AXONFLOW_PEP_HANDSHAKE:-}" ] && [ -n "${AXONFLOW_PEP_AUDIENCE:-}" ]; then
  # Bound the audience before it reaches the wire. The platform refuses
  # anything outside this grammar, so a malformed value would 400 every
  # governed call; refusing to build it here fails loudly at one place instead.
  # TWO checks, and the newline one is not redundant. `grep` is LINE-BASED, so
  # an audience of "aud\nhas spaces" matches on its FIRST line and passes a
  # `^...$` test that looks airtight - and the document then carries a raw
  # newline inside a JSON string, which is invalid JSON and which the platform
  # refuses as a malformed handshake on every governed call. The equality test
  # against a newline-stripped copy is what rejects a multi-line value before
  # the grammar check ever runs.
  _pep_flat=$(printf '%s' "$AXONFLOW_PEP_AUDIENCE" | tr -d '\n\r')
  if [ "$_pep_flat" = "$AXONFLOW_PEP_AUDIENCE" ] \
     && printf '%s' "$AXONFLOW_PEP_AUDIENCE" | LC_ALL=C grep -qE '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'; then
    # profile_version, pep_id, audience, capabilities - every member required,
    # in the platform encoder's member order. `capabilities` is ALWAYS present:
    # an omitted member is MALFORMED, while [] is the declaration "I discharge
    # nothing". Those are different facts with different outcomes.
    _pep_doc=$(printf '{"profile_version":1,"pep_id":"%s","audience":"%s","capabilities":[]}' \
      "claude-code-plugin" "$AXONFLOW_PEP_AUDIENCE")
    # RAW url-safe base64: the alphabet the platform's own encoder emits, with
    # padding stripped. `tr -d '\n'` because base64(1) wraps by default on Linux.
    AXONFLOW_PEP_HANDSHAKE=$(printf '%s' "$_pep_doc" \
      | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
    export AXONFLOW_PEP_HANDSHAKE
    unset _pep_doc _pep_flat
  else
    # Loud, and does NOT fall back to sending nothing silently: an operator who
    # set the variable believes a control is in force.
    echo "axonflow: AXONFLOW_PEP_AUDIENCE is malformed (want 1-128 bytes matching ^[A-Za-z0-9][A-Za-z0-9._:-]*$); no capability handshake will be sent" >&2
  fi
fi
