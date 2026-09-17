#!/usr/bin/env bash
# `exec` as the reader of a pipeline still runs grep with its options.
set -euo pipefail
printf '%s\n' alpha | exec grep -q alpha               # EXPECT exec
