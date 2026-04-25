# Contributing to AxonFlow Claude Code plugin

Thank you for your interest in contributing! Please open an issue or pull request via the [GitHub repository](https://github.com/getaxonflow/axonflow-claude-plugin).

## Development setup

The plugin is bash-script-based. Hooks live in `scripts/`; tests in `tests/`.

```bash
./tests/test-hooks.sh           # mock-MCP-server tests, no AxonFlow needed
./tests/test-hooks.sh --live    # against live AxonFlow on localhost:8080
```

## Pull request guidelines

1. Keep PRs focused — one feature or fix per PR.
2. Update `CHANGELOG.md` under `[Unreleased]` for user-visible changes.
3. Ensure `tests/test-hooks.sh` is green and the wire-shape contract gate passes.
4. New AxonFlow-wire-field reads: extend the relevant script's `jq` accesses on `$TOOL_RESULT` / `$SCAN_RESULT`. The wire-shape gate's refresh script auto-discovers them via the documented variable patterns; rerun `python3 scripts/wire-shape/refresh.py <specs_dir>` and commit the regenerated baseline.

## Baseline burndown policy

The wire-shape contract gate uses a baseline file (`tests/fixtures/wire-shape-baseline.json`) to grandfather pre-existing drift findings — the gate fails on any *new* drift but tolerates the listed entries. Baselines exist to land the gate without a giant cleanup PR; they are not intended to be permanent.

When your PR touches a baselined area, do one of:

- **Burn it down.** Resolve the drift in this PR (align script with spec, file a platform-side spec PR, or mark as Cat C), regenerate the baseline, and note "burndown: `<entry>`" in the PR description.
- **Justify it.** If the drift can't be resolved in this PR (different scope, blocked on a platform spec change, etc.), say so in the PR description in one line.

Reviewers will ask the burndown-or-justify question on PRs that touch baselined areas without addressing them.

## Wire-shape contract (Cat C three-bucket framework)

The plugin reads MCP-response field shapes from the AxonFlow agent. We track three buckets of drift:

1. **Canonical wire-bound schemas — gate-zero target.** `MCPCheckInputResponse`, `MCPCheckOutputResponse`. Every field the plugin reads on these schemas should trace to the agent OpenAPI spec, and every spec field should ideally be surfaced where useful. Drift here lands on the burndown queue and shrinks over time.
2. **Helper / advisory reads — accept non-zero drift.** Internal read variables that aren't AxonFlow-wire (Claude Code's own hook input/output, plugin manifest fields). These are out of scope for the wire-shape gate.
3. **`@sdkDerived` first-class marker (deferred).** When a script reads a field that's a plugin-side derivation rather than a wire field, mark it explicitly. Convention deferred until first real use case lands.

## Language-targeted reasoning (why bash gets a different gate shape)

The four AxonFlow SDKs (TS / Python / Go / Java) declare wire-bound types in source code and the gate compares those declarations to the OpenAPI spec. The Claude / Cursor / Codex plugins are bash scripts that read fields directly via `jq` — there is no typed declaration to walk. The bash gate instead enumerates jq accesses on known MCP-response variables (`TOOL_RESULT`, `SCAN_RESULT`) and treats those as the plugin's wire contract.

Bug classes the bash gate catches:
- script reads a field name that the spec doesn't declare → drift
- spec gains a field the script doesn't read → Cat B opportunity

Bug classes specific to TS/Python SDKs (transformer drift, falsey-clobber, sync wrapper signature lag) don't apply to bash plugins by construction — there are no transformers, `||` is shell-OR (not implicit-truthiness), and there are no sync/async wrappers.

## Questions

- Open a GitHub issue
- Email: hello@getaxonflow.com
