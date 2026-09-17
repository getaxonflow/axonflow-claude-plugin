#!/usr/bin/env bash
# Lines that must not hide the rest of the file, each followed by a line that
# must be reported: a here-document word escaped with a backslash, a word with
# hyphens, an ANSI-C quoted string holding an escaped quote, and a plain
# here-document whose body holds an indented copy of its word. Then grep run by
# `if`, and three-character long-option abbreviations.
set -euo pipefail
cat <<\EOF
it's a body line with an apostrophe
EOF
printf '%s\n' x | grep -q x                           # EXPECT after <<\EOF
cat <<END-OF-TEXT
it's another body line
END-OF-TEXT
printf '%s\n' x | grep -q x                           # EXPECT after <<END-OF-TEXT
q=$'it\'s'
printf '%s\n' x | grep -q x                           # EXPECT after $'it\'s'
cat <<EOF
  EOF
it's still the body
EOF
printf '%s\n' x | grep -q x                           # EXPECT after an indented copy of the word
printf '%s\n' x | if grep -q x; then :; fi            # EXPECT grep run by if
printf '%s\n' x | grep --q x                          # EXPECT --q
printf '%s\n' x | grep --s x                          # EXPECT --s
printf '%s\n' x | grep --m=1 x                        # EXPECT --m
