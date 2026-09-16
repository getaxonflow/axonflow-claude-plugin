#!/usr/bin/env bash
# Positive shapes: each marked line must be reported once.
set -eo pipefail
text="alpha"
printf '%s\n' "$text" | grep -q alpha                # EXPECT plain
printf '%s\n' "$text" | egrep -q 'al+pha'             # EXPECT egrep
printf '%s\n' "$text" | fgrep -q alpha                # EXPECT fgrep
printf '%s\n' "$text" | grep --quiet alpha            # EXPECT --quiet
printf '%s\n' "$text" | grep --silent alpha           # EXPECT --silent
printf '%s\n' "$text" | grep -iqE 'ALPHA'             # EXPECT a cluster holding q
printf '%s\n' "$text" | grep -e alpha -q              # EXPECT -q after the pattern
printf '%s\n' "$text" |                               # EXPECT a trailing pipe
  grep -q alpha
# EXPECT-NEXT
printf '%s\n' "$text" \
  | grep -q alpha
printf '%s\n' "$text" |& grep -q alpha                # EXPECT |&
printf '%s\n' "a # b" | grep -q a                     # EXPECT a # inside quotes
printf '%s\n' "$text" | command grep -q alpha         # EXPECT command grep
printf '%s\n' "$text" | /usr/bin/grep -q alpha        # EXPECT a path to grep
printf '%s\n' "$text" | grep -q alpha  # a comment quoting `x | grep -q y` # EXPECT once
