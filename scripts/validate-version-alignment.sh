#!/usr/bin/env bash
# Validates that the plugin's version is aligned across every source of truth.
#
# WHY THIS EXISTS (v1.9.1): `.claude-plugin/plugin.json` is the ON-THE-WIRE
# version — `scripts/client-header.sh` reads its `.version` into the
# `X-Axonflow-Client: claude-code-plugin/<version>` header, which the platform
# records for per-plugin distribution telemetry and which `scripts/version-check.sh`
# compares against the platform floor. In v1.8.0 and v1.9.0 the release commits
# bumped only `marketplace.json` + `CHANGELOG.md` and left `plugin.json` at 1.7.0,
# so every 1.7.0 / 1.8.0 / 1.9.0 install reported itself as `1.7.0` — collapsing
# three releases into one telemetry bucket and mis-gating version-check. This gate
# fails the build unless plugin.json, both marketplace.json version fields, and the
# top CHANGELOG entry all match, so the wire version can never drift again.
#
# Run locally: ./scripts/validate-version-alignment.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ERRORS=0

# Canonical version = the latest released CHANGELOG entry (first `## [x.y.z]`).
LATEST_VERSION=$(grep -m1 -E '^## \[[0-9]' CHANGELOG.md | sed -E 's/^## \[([^]]+)\].*/\1/')
if [ -z "$LATEST_VERSION" ]; then
  echo "❌ Could not extract version from CHANGELOG.md (expected a '## [x.y.z]' heading)"
  exit 1
fi
echo "📋 Latest CHANGELOG version: $LATEST_VERSION"
echo ""

check() { # <label> <actual-value>
  if [ "$2" = "$LATEST_VERSION" ]; then
    echo "  ✅ $1 — $2"
  else
    echo "  ❌ $1 — $2 (expected $LATEST_VERSION)"
    ERRORS=$((ERRORS + 1))
  fi
}

check ".claude-plugin/plugin.json (.version) [ON-THE-WIRE X-Axonflow-Client]" \
  "$(jq -r '.version // empty' .claude-plugin/plugin.json)"
check ".claude-plugin/marketplace.json (.metadata.version)" \
  "$(jq -r '.metadata.version // empty' .claude-plugin/marketplace.json)"
check ".claude-plugin/marketplace.json (.plugins[0].version)" \
  "$(jq -r '.plugins[0].version // empty' .claude-plugin/marketplace.json)"
# .mcp.json carries the MCP-plane version as a hardcoded literal inside the
# headersHelper inline (X-Axonflow-Client: claude-code-plugin/<version>). It can
# resolve the plugin dir at runtime, so the version is baked in and MUST be
# kept in lockstep here — the whole point of v1.9.1 was a version that drifted.
check ".mcp.json (X-Axonflow-Client header) [ON-THE-WIRE MCP plane]" \
  "$(grep -oE 'claude-code-plugin/[^\"]+' .mcp.json | head -1 | sed 's#.*/##')"

echo ""
if [ "$ERRORS" -ne 0 ]; then
  echo "❌ $ERRORS version reference(s) out of alignment with CHANGELOG $LATEST_VERSION."
  echo "   Every release MUST bump ALL of them together: plugin.json (.version),"
  echo "   marketplace.json (.metadata.version AND .plugins[0].version), and CHANGELOG.md."
  exit 1
fi
echo "✅ All version references aligned at $LATEST_VERSION"
