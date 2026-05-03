# Runtime End-to-End Tests — Claude Code plugin

Tests in this directory MUST invoke the plugin through Claude Code's runtime — plugin loaded via the marketplace install path, then triggered through Claude Code's slash-command, skill, or hook dispatch. Calling the plugin's TypeScript classes or hook handlers directly is not a runtime test — that's a unit test, which lives under `tests/`.

If Claude Code can't expose your feature yet, the feature isn't ready to ship.

## Why this directory exists

A May 3, 2026 audit found multiple AxonFlow capabilities (audit search, decision explain, override CRUD) where the platform endpoint and SDK method existed for months but no plugin skill/hook ever wired them up. Users running Claude Code with the AxonFlow plugin could not reach the capability. The fix: every user-facing AxonFlow feature exposed via this plugin must have a test in this directory that invokes through Claude Code's runtime.

The single rule:

> **If a user cannot reach the feature from their runtime, we did not ship a feature, we shipped a library.**

See `axonflow-business-docs/engineering/E2E_EXAMPLES_TESTING_WORKFLOW.md` Policy section for the full methodology.

## What "runtime" means here

The runtime is the Claude Code CLI. A test must:

- Install the plugin through Claude Code's plugin/marketplace path — not by symlinking from a relative source path.
- Launch a real Claude Code session with the plugin loaded.
- Trigger the capability through Claude Code's surface — slash-command, skill invocation, or hook firing on a tool call — rather than importing the plugin's TypeScript files.

If a test imports from `src/` and calls the AxonFlow client class, it is a unit test or an integration test against the AxonFlow stack. That belongs under `tests/`, not here.

## Layout

```
runtime-e2e/
  README.md                    # this file
  <feature-name>/              # one folder per feature
    test.sh                    # bash runner; invokes through claude code
    README.md                  # 5 lines: prereqs, what it asserts, how to run
```

## Running

Each test folder has its own README with prereqs and run instructions. Most tests assume:

- An AxonFlow community-saas-style stack is reachable (default endpoint or via env var).
- A working `claude` CLI (Claude Code) is installed and on `$PATH`.
- The plugin is built locally so the marketplace install path can resolve it.

## Adding a test

1. Confirm you can invoke the feature through `claude` — install the plugin, then trigger via slash-command/skill/hook. If you can't, the answer is to fix the plugin's skill/hook registration, not to write a TypeScript-import test.
2. Create the folder, write `test.sh` and `README.md`.
3. Update `axonflow-business-docs/engineering/FEATURE_RUNTIME_COVERAGE.md` to mark the new green cell under the Claude Code column.
4. Reference the test in the PR that wires the feature.
