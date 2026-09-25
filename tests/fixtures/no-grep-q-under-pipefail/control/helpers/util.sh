#!/usr/bin/env bash
# The same relative path as sourced-var/helpers/util.sh, sourced by nothing
# and never under pipefail: `helpers/util.sh` alone does not say which file a
# runner means, so it is resolved from the runner's own directories. Not
# reported.
has_alpha() {
  printf '%s\n' "$1" | grep -q alpha
}
