#!/usr/bin/env bash
# Sets pipefail and sources a helper through a variable naming a directory
# above this one, as the plugin's suites do with $PLUGIN_DIR.
set -euo pipefail
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN_DIR/helpers/util.sh"
