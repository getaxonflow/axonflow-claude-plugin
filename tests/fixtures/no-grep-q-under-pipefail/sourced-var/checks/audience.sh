#!/usr/bin/env bash
# Sets nothing, is not under lib/, and is sourced as "$HELPER_PATH".
valid_audience() {
  printf '%s' "$1" | LC_ALL=C grep -qE '^[a-z]+$'      # EXPECT
}
