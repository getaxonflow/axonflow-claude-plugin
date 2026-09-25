#!/usr/bin/env bash
# Sourced by runner.sh; sets nothing and is not under lib/.
state() { printf 'ready\n'; }
is_ready() {
  state | grep -q ready   # EXPECT
}
