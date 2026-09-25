#!/usr/bin/env bash
# pipefail set as its own option after another: `set -e -o pipefail`.
set -e -o pipefail
printf '%s\n' alpha | grep -q alpha                   # EXPECT
