#!/usr/bin/env bash
# Sets pipefail and sources a helper through a variable that holds its whole
# path, as tests/test-pep-handshake.sh does.
set -uo pipefail
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_PATH="${PLUGIN_DIR}/checks/audience.sh"
. "$HELPER_PATH"
