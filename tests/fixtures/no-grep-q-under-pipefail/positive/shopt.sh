#!/usr/bin/env bash
# pipefail set through shopt: `shopt -so pipefail`.
shopt -so pipefail
printf '%s\n' alpha | grep -q alpha                   # EXPECT
