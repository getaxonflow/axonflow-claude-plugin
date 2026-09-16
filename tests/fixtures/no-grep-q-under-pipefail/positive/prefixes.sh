#!/usr/bin/env bash
# Positive shapes: what runs grep, the early-exit options, and lines that must
# not hide the rest of the file. Each marked line must be reported once.
set -eo pipefail
text="alpha"
printf '%s\n' "$text" | LC_ALL=C grep -q alpha        # EXPECT an assignment before grep
printf '%s\n' "$text" | env LC_ALL=C grep -q alpha    # EXPECT env
printf '%s\n' "$text" | env -u LANG grep -q alpha     # EXPECT env -u NAME
printf '%s\n' "$text" | timeout 5 grep -q alpha       # EXPECT timeout N
printf '%s\n' "$text" | timeout -s KILL 5 grep -q a   # EXPECT timeout -s SIG N
printf '%s\n' "$text" | command -p grep -q alpha      # EXPECT command -p
printf '%s\n' "$text" | grep -qm1 alpha               # EXPECT a cluster with a digit
printf '%s\n' "$text" | grep -m1 alpha >/dev/null     # EXPECT -m stops at a count
printf '%s\n' "$text" | grep --max-count=1 alpha      # EXPECT --max-count
printf '%s\n' "$text" | grep -l alpha >/dev/null      # EXPECT -l
printf '%s\n' "$text" | grep -L beta >/dev/null       # EXPECT -L
bits=$((1 << SHIFT))
printf '%s\n' "$text" | grep -q alpha                 # EXPECT after an arithmetic shift
(( bits <<= 1 ))
printf '%s\n' "$text" | grep -q alpha                 # EXPECT after an arithmetic <<=
grep -q alpha <<<word
printf '%s\n' "$text" | grep -q alpha                 # EXPECT after a here-string of a bare word
printf '%s\n' "$text" | nice -n 5 grep -q alpha       # EXPECT nice -n N
printf '%s\n' "$text" | stdbuf -oL grep -q alpha      # EXPECT stdbuf
printf '%s\n' "$text" | time grep -q alpha            # EXPECT time
printf '%s\n' "$text" | sudo -u root grep -q alpha    # EXPECT sudo -u USER
printf '%s\n' "$text" | \grep -q alpha                # EXPECT a backslashed grep
printf '%s\n' "$text" | "grep" -q alpha               # EXPECT a quoted grep
printf '%s\n' "$text" | { grep -q alpha; }            # EXPECT a brace group
printf '%s\n' "$text" | grep --files-with-matches a   # EXPECT --files-with-matches
printf '%s\n' "$text" | grep --files-without-match b  # EXPECT --files-without-match
printf '%s\n' "$text" | grep --qui alpha              # EXPECT an abbreviated --quiet
printf '%s\n' "$text" | grep --max-c=1 alpha          # EXPECT an abbreviated --max-count
printf '%s\n' "$text" | grep --files-with a           # EXPECT a prefix of two early options
