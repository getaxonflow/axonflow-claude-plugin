#!/usr/bin/env bash
# Sourced as "$(dirname "$0")/../helpers/by-dirname.sh".
f() { printf '%s\n' "$1" | grep -q alpha; }           # EXPECT
