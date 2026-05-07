# Runtime E2E — Claude can invoke each V1 Plugin Pro MCP tool

Drives the **real `claude` CLI** with the plugin loaded against the
**real hosted AxonFlow agent** at `https://try.getaxonflow.com` and
asserts that the AI model can actually invoke each of the five V1 Plugin
Pro MCP tools end-to-end. Per HARD RULE #0
(`feedback_runtime_proof_is_definition_of_done.md`) — every byte that
flows through the test came from the real plugin, real CLI, real agent,
real DB.

## What this test exercises

For each tool in the V1 PRD §V1 differentiator table, the test:

1. Spawns `claude --print --output-format stream-json` with
   `--plugin-dir <repo>` so this plugin's MCP-server config is loaded.
2. Prompts the agent to invoke the tool by its fully-prefixed name.
3. Parses the captured `stream-json` and asserts:
   - The `system.init` block reports
     `mcp_servers: [{name: "plugin:axonflow:axonflow", status: "connected"}]`.
   - A `tool_use` block with the matching name appears in the agent
     stream.
   - The corresponding `tool_result` body matches the locked V1 shape
     (differentiators / approval_id / policy id / tenant_id, etc.).

The expected tool name prefix is
`mcp__plugin_axonflow_axonflow__<tool>` — Claude Code 2.1.132 collapses
the plugin's MCP-server identity (`.claude-plugin/plugin.json` name=
`axonflow`, `.mcp.json` server=`axonflow`) into that namespace.

## Per-tool expectations

| # | Tool                              | Free-tier expectation                                                                    |
|---|-----------------------------------|------------------------------------------------------------------------------------------|
| 1 | `axonflow_list_pro_features`      | Invoked → 5 differentiators + `9.99` price + locked V1 buy URL                           |
| 2 | `axonflow_get_cost_estimate`      | **Hidden** from `init.tools` (Pro-only per ADR-049 §5; assert absence, don't invoke)     |
| 3 | `axonflow_request_approval`       | Invoked → `approval_id` non-empty                                                        |
| 4 | `axonflow_create_tenant_policy`   | Invoked → policy `id` non-empty (uses a benign `pattern` so static policies don't block) |
| 5 | `axonflow_get_tenant_id`          | Invoked → matching `tenant_id` + `upgrade_url` to `getaxonflow.com/pricing`              |

## Why test 2 asserts hidden, not invoked

`axonflow_get_cost_estimate` is the V1 Pro paywall tool. The agent
**only** advertises it to Pro-tier sessions — a Free-tier `tools/list`
call doesn't include it at all, so the agent literally cannot invoke
it. The locked V1 envelope shape (`limit_type=feature_pro_only` + buy
URL) is exercised end-to-end against the wire by
`axonflow-openclaw-plugin/runtime-e2e/v1_pro_proxy_tools/test.sh` which
calls the MCP tool directly via JSON-RPC and bypasses tier gating. The
two tests cover the same Pro-only contract from opposite directions:
the OpenClaw test proves the wire shape; this test proves the visibility
gate.

## Tool allowlisting

Claude CLI prompts per-tool by default. The test bypasses this with
`--dangerously-skip-permissions` and `--allowedTools "mcp__axonflow__*"`
on the `claude --print` invocation (see
`runtime-e2e/_lib/claude-runtime.sh:run_claude_with_tool`). Without
that, every `tools/call` would block on a permission dialog and the
test would deadlock.

**Don't drop these flags** when iterating on the test or the
`run_claude_with_tool` helper. If you need to explore tool-permission
behaviour for a different test, use a separate helper — keep this
test's automation guarantee. Confirm one trivial tool fires without a
prompt before sending the full 5-tool prompt: the
`run_claude_with_tool` helper already covers that path; what fails
silently is when a future change to the helper drops `--dangerously-skip-permissions`
and the test starts hanging on the first tool.

## Pre-conditions

The test handles all of these automatically and SKIPs cleanly when
unavailable:

- `claude` and `jq` on `PATH`.
- `${AGENT_URL}/health` reachable (defaults to `https://try.getaxonflow.com`).
- Either `TENANT=` and `SECRET=` env vars (re-use an existing tenant)
  or `/api/v1/register` lets us register a fresh one. The endpoint has
  a per-IP 5/hour rate limit; reuse env if you're iterating.
- Optional: AWS credentials + `db_helpers.sh` from
  `axonflow-enterprise/runtime-e2e/v1_paid_tier_staging/lib/`. When
  available, the test cleans the tenant's
  `hitl_approval_queue` + `dynamic_policies` rows before the run so the
  Free-tier 1/7d HITL window and 2-active-policy max don't trip
  spuriously on re-runs against the same tenant.

## License-token isolation

The plugin's `scripts/mcp-auth-headers.sh` auto-loads
`~/.config/axonflow/license-token.json` on every invocation and stamps
its bytes into the `X-License-Token` header. If a previous Pro-tier
session left a token on disk for tenant A and the current run targets
tenant B, the agent's `PluginClaimMiddleware` rejects the request as a
cross-tenant token binding violation — which surfaces as
`mcp_servers: [{...,"status":"failed"}]` in the stream-json, NOT a tier
downgrade.

The test mitigates this by moving any pre-existing
`~/.config/axonflow/license-token.json` aside for the duration of the
run (saved to `<file>.runtime-e2e-bak.<pid>`) and restoring it via the
`EXIT` trap.

## Usage

```bash
# Default — register a fresh tenant against try.getaxonflow.com:
bash runtime-e2e/v1_pro_mcp_tools_invocable/test.sh

# Re-use an existing tenant (avoids the per-IP /register rate limit):
TENANT=cs_xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  bash runtime-e2e/v1_pro_mcp_tools_invocable/test.sh

# Self-hosted:
AGENT_URL=http://localhost:8080 \
  AXONFLOW_AUTH=$(printf '%s:%s' demo-client demo-secret | base64) \
  bash runtime-e2e/v1_pro_mcp_tools_invocable/test.sh
```

Captured evidence lands under
`runtime-e2e/v1_pro_mcp_tools_invocable/EVIDENCE/<utc-ts>/`:

- `<tool>.jsonl` — per-tool stream-json from the host CLI
- `<tool>_result.txt` — extracted tool_result body for the assertion
- `<tool>_expectation.txt` — the assertion key the test ran
- `summary.txt` — top-line PASS/FAIL with tenant ID

The evidence dir contains tenant_id values (public identifiers) but
**never** the bcrypt-validated `secret` Basic-auth credential or any
license token — both are scrubbed by the assertion paths and only ever
flow on the wire as `Authorization: Basic <base64>` headers.
