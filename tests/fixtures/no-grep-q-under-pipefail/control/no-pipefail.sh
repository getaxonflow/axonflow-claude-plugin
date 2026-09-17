#!/usr/bin/env bash
# Never sets pipefail: the pipeline's status is grep's own.
set -eu
printf 'ready\n' | grep -q ready && echo up
