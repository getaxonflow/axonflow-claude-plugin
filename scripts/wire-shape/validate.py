#!/usr/bin/env python3
"""Wire-shape contract gate — PR-blocking validator.

Compares the AxonFlow Claude Code plugin's bash-script jq-field-reads
against the AxonFlow agent OpenAPI spec at the SHA pinned in
tests/fixtures/wire-shape-baseline.json. Fails on drift NOT covered
by the baseline.

Usage:
  AXONFLOW_OPENAPI_SPECS_DIR=<specs_dir> python3 scripts/wire-shape/validate.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Add lib.py's dir to path so `import lib` works regardless of cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402


def main() -> int:
    specs_dir_env = os.environ.get("AXONFLOW_OPENAPI_SPECS_DIR")
    if not specs_dir_env:
        print(
            "⏭️  AXONFLOW_OPENAPI_SPECS_DIR not set; wire-shape gate skipped.\n"
            "    The dedicated CI job clones getaxonflow/axonflow at the pinned\n"
            "    SHA and exports this variable before running the validator.",
        )
        return 0
    specs_dir = Path(specs_dir_env)
    if not specs_dir.is_dir():
        print(f"::error::AXONFLOW_OPENAPI_SPECS_DIR is not a directory: {specs_dir}")
        return 2

    plugin_reads = lib.discover_plugin_reads(lib.SCRIPTS_DIR)
    schemas = lib.load_schemas(specs_dir)
    drift, unmapped = lib.compute_drift(plugin_reads, schemas)
    baseline = lib.load_baseline()

    base_drift = baseline.get("per_type_drift", {})
    base_unmapped = baseline.get("unmapped_in_spec", [])

    failed = False

    # New per-type drift not in baseline.
    new_drift_lines: list[str] = []
    for name, d in drift.items():
        expected = base_drift.get(name, {"plugin_only": [], "spec_only": []})
        new_plugin_only = sorted(set(d["plugin_only"]) - set(expected.get("plugin_only", [])))
        new_spec_only = sorted(set(d["spec_only"]) - set(expected.get("spec_only", [])))
        if new_plugin_only or new_spec_only:
            new_drift_lines.append(f"  {name}:")
            if new_plugin_only:
                new_drift_lines.append(f"    NEW plugin-only: {', '.join(new_plugin_only)}")
            if new_spec_only:
                new_drift_lines.append(f"    NEW spec-only:   {', '.join(new_spec_only)}")
    if new_drift_lines:
        print("::error::wire-shape: NEW per-type drift not in baseline")
        for line in new_drift_lines:
            print(line)
        print()
        print(
            "Fix: align the script's jq accesses with the spec, OR (if the agent emits this field but the spec doesn't document it) file a platform-side issue and add the entry to baseline by re-running refresh.",
        )
        failed = True

    # Newly-unmapped schemas (plugin reads from a schema the spec doesn't have).
    new_unmapped = sorted(set(unmapped) - set(base_unmapped))
    if new_unmapped:
        print("::error::wire-shape: NEW unmapped schemas (plugin reads them, spec doesn\'t)")
        for n in new_unmapped:
            print(f"  {n}")
        failed = True

    # Stale baseline entries — burned down without refresh.
    stale_drift = sorted(set(base_drift.keys()) - set(drift.keys()))
    stale_unmapped = sorted(set(base_unmapped) - set(unmapped))
    if stale_drift or stale_unmapped:
        print("::error::wire-shape: stale baseline entries — burned down but baseline still lists")
        for n in stale_drift:
            print(f"  drift: {n}")
        for n in stale_unmapped:
            print(f"  unmapped: {n}")
        print("Re-run with refresh.py to update.")
        failed = True

    if failed:
        return 1

    drift_count = len(drift)
    unmapped_count = len(unmapped)
    print(
        f"wire-shape: clean — {drift_count} per-type drift entry(ies), "
        f"{unmapped_count} unmapped schema(s), all baselined.",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
