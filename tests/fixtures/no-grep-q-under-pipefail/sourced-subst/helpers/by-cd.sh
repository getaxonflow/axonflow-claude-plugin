#!/usr/bin/env bash
# Sourced as "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../helpers/by-cd.sh".
g() { printf '%s\n' "$1" | grep -q beta; }            # EXPECT
