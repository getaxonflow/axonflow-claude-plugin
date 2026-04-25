"""Wire-shape contract gate — shared helpers for the AxonFlow Claude Code plugin.

The plugin is bash-script-based and reads fields from AxonFlow agent MCP
responses via jq (e.g. `jq -r '.allowed'`). This gate diffs the set of
fields the plugin reads against the agent's OpenAPI spec at a pinned
SHA. Drift NOT covered by the baseline blocks merge.

Mirrors the four AxonFlow SDK wire-shape gates and the OpenClaw plugin
gate per ADR-047, adapted for bash-script plugins:
  - Authoritative source: OpenAPI spec, loaded from $AXONFLOW_OPENAPI_SPECS_DIR
  - Plugin-side surface: hand-maintained manifest of which MCP-response
    schemas the plugin reads, and which fields it accesses on each.
    Refresh script regenerates the manifest from script source via the
    well-known jq-on-MCP-result patterns; validate then compares the
    manifest to the spec.
  - Drift entries are baselined and burned down over time.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = PLUGIN_ROOT / "scripts"
BASELINE_PATH = PLUGIN_ROOT / "tests" / "fixtures" / "wire-shape-baseline.json"

# Map: variable-name-holding-MCP-result → schema name. The bash scripts
# extract the inner MCP tool-result text into one of these variables,
# then jq fields off of it. The gate scans for `jq -r '.X'` on inputs
# that are identifiable as one of these variables.
#
# Update this map when adding a new MCP-call site that reads from a
# different schema.
MCP_RESULT_VARS = {
    "TOOL_RESULT": "MCPCheckInputResponse",  # pre-tool-check.sh
    "SCAN_RESULT": "MCPCheckOutputResponse",  # post-tool-audit.sh redaction scan
}

# Field accesses the gate intentionally ignores. Mostly noise from
# nested envelope reads (.result.content[0].text is the JSON-RPC
# wrapper, not a wire field) and language-server-feature reads.
IGNORED_FIELDS = {
    "result",
    "content",
    "text",
    "error",  # JSON-RPC error
    "message",
    "code",
}


def _load_yaml(path: Path):
    """Lazy-import yaml; preserve duplicate-key tolerance.

    Prefer ruamel.yaml or PyYAML's BaseLoader so duplicate-key declarations
    don't crash (orchestrator-api.yaml has known intra-file duplicates).
    """
    import yaml  # type: ignore

    class _Loader(yaml.SafeLoader):
        pass

    # PyYAML by default *silently* lets later keys win on duplicates, which
    # is what we want for spec walking. No override needed.
    with path.open() as f:
        return yaml.load(f, Loader=_Loader)


def load_schemas(specs_dir: Path) -> dict[str, list[str]]:
    """Walk every *.yaml under specs_dir and return name → sorted fields.

    Last-loaded declaration wins on cross-spec collision.
    """
    merged: dict[str, list[str]] = {}
    for f in sorted(specs_dir.glob("*.yaml")):
        try:
            doc = _load_yaml(f)
        except Exception as exc:  # noqa: BLE001 - any parse error skips the file
            print(f"::warning::failed to parse {f.name}: {exc}")
            continue
        if not isinstance(doc, dict):
            continue
        components = (doc.get("components") or {}).get("schemas") or {}
        if not isinstance(components, dict):
            continue
        for name, schema in components.items():
            fields = _extract_fields(schema)
            if fields is not None:
                merged[name] = fields
    return merged


def _extract_fields(schema):
    if not isinstance(schema, dict):
        return None
    if schema.get("type") == "object" and isinstance(schema.get("properties"), dict):
        return sorted(schema["properties"].keys())
    if isinstance(schema.get("allOf"), list):
        merged: set[str] = set()
        for sub in schema["allOf"]:
            sub_fields = _extract_fields(sub)
            if sub_fields:
                merged.update(sub_fields)
        if merged:
            return sorted(merged)
    return None


JQ_FIELD_RE = re.compile(
    r"""\$([A-Z_][A-Z0-9_]*)["']?\s*\)?\s*\|\s*jq\s+-r\s+'(?P<expr>[^']+)'""",
)
# Matches `$VAR" | jq -r '...'` or `$VAR | jq -r '...'`.
# expr group is the jq filter text.

LEAF_FIELD_RE = re.compile(r"\.([a-z_][a-zA-Z0-9_]*)")


def discover_plugin_reads(scripts_dir: Path) -> dict[str, set[str]]:
    """Scan bash scripts for `jq -r '.X'` accesses on MCP-result variables.

    Returns a dict {schema_name: set_of_field_names}.
    """
    reads: dict[str, set[str]] = {schema: set() for schema in MCP_RESULT_VARS.values()}
    for script in sorted(scripts_dir.glob("*.sh")):
        text = script.read_text()
        for match in JQ_FIELD_RE.finditer(text):
            var = match.group(1)
            schema = MCP_RESULT_VARS.get(var)
            if schema is None:
                continue
            expr = match.group("expr")
            for f in LEAF_FIELD_RE.findall(expr):
                if f in IGNORED_FIELDS:
                    continue
                reads[schema].add(f)
    return reads


def compute_drift(
    plugin_reads: dict[str, set[str]],
    schemas: dict[str, list[str]],
) -> tuple[dict[str, dict[str, list[str]]], list[str]]:
    """Compute per-schema drift and unmapped schemas.

    Returns (drift, unmapped_in_spec).
    """
    drift: dict[str, dict[str, list[str]]] = {}
    unmapped: list[str] = []
    for schema, fields in plugin_reads.items():
        spec_fields = schemas.get(schema)
        if spec_fields is None:
            unmapped.append(schema)
            continue
        spec_set = set(spec_fields)
        plugin_only = sorted(fields - spec_set)
        spec_only = sorted(spec_set - fields)
        if plugin_only or spec_only:
            drift[schema] = {
                "plugin_only": plugin_only,
                "spec_only": spec_only,
            }
    return drift, sorted(unmapped)


def load_baseline() -> dict:
    if not BASELINE_PATH.exists():
        raise SystemExit(f"baseline missing: {BASELINE_PATH}")
    return json.loads(BASELINE_PATH.read_text())


def write_baseline(data: dict) -> None:
    BASELINE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = BASELINE_PATH.with_suffix(BASELINE_PATH.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.rename(BASELINE_PATH)
