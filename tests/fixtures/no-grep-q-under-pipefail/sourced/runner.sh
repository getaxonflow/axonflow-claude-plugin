#!/usr/bin/env bash
# Sets pipefail and sources util.sh: util.sh's pipeline runs under pipefail.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/util.sh"
if grep -q ready <<<"$(state)"; then echo up; fi
