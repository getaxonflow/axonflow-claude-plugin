#!/usr/bin/env bash
# Sets nothing, is not under lib/, and is sourced as "$PLUGIN_DIR/helpers/util.sh".
has_alpha() {
  printf '%s\n' "$1" | grep -q alpha                  # EXPECT
}
