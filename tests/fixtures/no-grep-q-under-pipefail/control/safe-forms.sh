#!/usr/bin/env bash
# Sets pipefail and holds only shapes that must not be reported.
set -euo pipefail
body='{"ok":true}'
log="$(printf 'one\ntwo ready\n')"
if grep -q '"ok":true' <<<"$body"; then echo 1; fi
if grep -q ready <<<"$(printf '%s' "$log")"; then echo 2; fi
if printf '%s' "$log" | grep ready >/dev/null; then echo 3; fi
if grep -q set "$0"; then echo 4; fi
if printf '%s' "$log" | grep -c ready >/dev/null; then echo 5; fi
if grep -qE 'ready|busy' <<<"$log"; then echo 6; fi
grep -q none <<<"$body" || grep -q ok <<<"$body"
# Never `printf x | grep -q x` under pipefail.
if grep -q two <<<"$log"; then echo 7; fi   # nor `a | grep -q b`
cat <<'DOC'
printf x | grep -q x
DOC
bash -c 'printf x | grep -q x' && echo 8
ssh host "docker ps | grep -q api" || true
ok="$(printf '%s\n' "$body" | grep ok >/dev/null && echo true)"
