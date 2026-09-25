#!/usr/bin/env bash
# Sets pipefail; a q, m, l or L that is an argument, not an option, is not an
# early exit. Nothing is reported.
set -euo pipefail
text="alpha q"
printf '%s\n' "$text" | grep -eq >/dev/null
printf '%s\n' "$text" | grep -e -q >/dev/null
printf '%s\n' "$text" | grep -A1 -e alpha >/dev/null
printf '%s\n' "$text" | grep --regexp -q >/dev/null
printf '%s\n' "$text" | grep -- -q >/dev/null
printf '%s\n' "$text" | LC_ALL=C grep alpha >/dev/null
printf '%s\n' "$text" | env grep -c alpha >/dev/null
printf '%s\n' "$text" | grep --fi=patterns.txt >/dev/null
printf '%s\n' "$text" | grep --regex=-q >/dev/null
printf '%s\n' "$text" | grep --co alpha >/dev/null
