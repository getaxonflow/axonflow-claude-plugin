# governance-lifecycle — runtime integration test

**Asserts:** Claude Code chains multiple W2 tools in a single conversation. Read-only subset (no license required): agent invokes both `search_audit_events` AND `list_overrides` in one prompt, both succeed, and the agent reports a combined result. Full lifecycle (create → list → explain → revoke → list) requires an evaluation+ license to seed an override-able policy; gated on `AXONFLOW_LICENSE` env var.

**Why this exists alongside the per-feature tests:** per-feature tests prove each tool dispatches in isolation. This test proves the features cohere — multi-tool sessions don't break, tool results don't confuse the agent into stopping the chain.

**Prereqs:** `claude` CLI on PATH and authenticated; `jq`; live AxonFlow stack reachable at `$AXONFLOW_ENDPOINT`. For the full lifecycle: `AXONFLOW_LICENSE` set.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/governance-lifecycle/test.sh
```
