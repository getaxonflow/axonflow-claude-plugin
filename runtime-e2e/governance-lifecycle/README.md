# governance-lifecycle — runtime integration test

**Asserts:** one Claude Code session runs `list_overrides`, `create_override`, `list_overrides`, `delete_override` and `search_audit_events` in order. Both writes answer the retired-write tool error (`LEGACY_POLICY_WRITE_FROZEN: `), the reads answer, the platform's override count (read directly before and after) does not move, and the agent's final message reports exactly that state.

**Why this exists alongside the per-feature tests:** per-feature tests prove each tool dispatches in isolation. This one proves a multi-tool session survives the retired writes: a tool error does not stop the chain, and the agent reports the platform's state rather than an invented one.

**Prereqs:** `claude` CLI on PATH and authenticated; `jq`; a live AxonFlow v11.0.0 stack reachable at `$AXONFLOW_ENDPOINT` (never production: nothing here needs it). The suite presents `X-User-Email` through the plugin's MCP headersHelper (`AXONFLOW_USER_EMAIL`, default `claude-runtime-e2e@axonflow-test.invalid`) and on its own direct calls.

**Required deployment posture:** `AXONFLOW_TRUST_IDENTITY_HEADERS=true` on the AxonFlow **agent**. The override writes are scoped to an individual user, and without a trusted per-user identity the platform refuses them for identity before it answers the retirement, which this suite reports as a failure with the remediation. Only enable it when every hop that can reach the agent asserts end-user identity from a validated source.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/governance-lifecycle/test.sh
```
