#!/usr/bin/env -S bash -eo pipefail
# pipefail set by the interpreter line alone.
printf '%s\n' alpha | grep -q alpha                   # EXPECT
