#!/usr/bin/env bash
# `shopt -uo pipefail` turns it off; `echo set -o pipefail` only prints. Not in
# scope, nothing reported.
shopt -uo pipefail
echo set -o pipefail
printf '%s\n' alpha | grep -q alpha
