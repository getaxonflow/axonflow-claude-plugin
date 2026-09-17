#!/usr/bin/env bash
# pipefail set among long options: `set -o errexit -o pipefail`.
set -o errexit -o nounset -o pipefail
printf '%s\n' alpha | grep -q alpha                   # EXPECT
