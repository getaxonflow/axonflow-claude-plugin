#!/usr/bin/env bash
# Positive shapes: a pipeline inside a command substitution runs in this
# shell's options, quoted or not. Each marked line must be reported once, at
# its own line.
set -euo pipefail
status="200"
ok="$(echo "$status" | grep -qE '^(200|201)$' && echo true || echo false)"    # EXPECT inside "$(...)"
ok=$(echo "$status" | grep -q 200 && echo true)                               # EXPECT inside $(...)
ok="`echo "$status" | grep -q 200 && echo true`"                              # EXPECT inside "`...`"
listed=$(for f in a b; do
    printf '%s\n' "$f" | grep -q a && echo "$f"                               # EXPECT a line inside a multi-line $(...)
    printf '%s\n' "$f" | grep -q b && echo "$f"                               # EXPECT the next line, reported on its own
done)
# A "$(...)" on a quoted string's second line: reported at the line the
# statement starts.
# EXPECT-NEXT
note="first line
$(printf '%s\n' "$status" | grep -q 200 && echo yes)"
