#!/usr/bin/env bash
# Sets pipefail and sources helpers through command substitutions with their
# own quotes, as many suites locate their libraries.
set -euo pipefail
. "$(dirname "$0")/../helpers/by-dirname.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../helpers/by-cd.sh"
