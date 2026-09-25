# create-override — runtime E2E

**Asserts:** session overrides are retired from AxonFlow v11.0.0, and the plugin surface says so. Directly, MCP `create_override` with `X-User-Email` answers a tool error beginning `LEGACY_POLICY_WRITE_FROZEN: ` and REST `POST /api/v1/overrides` answers HTTP 409 `LEGACY_POLICY_WRITE_FROZEN`. Through Claude Code, the agent invokes `mcp__plugin_axonflow_axonflow__create_override` and its tool_result is that tool error; the agent's own final message (the stream's `result` event, which does not contain the prompt) reports `frozen: true`; and the `list_overrides` count does not move.

**Prereqs:** `claude` CLI on PATH and authenticated; `jq`; a live AxonFlow v11.0.0 stack reachable at `$AXONFLOW_ENDPOINT` (never production: nothing here needs it). The suite presents `X-User-Email` through the plugin's MCP headersHelper (`AXONFLOW_USER_EMAIL`, default `claude-runtime-e2e@axonflow-test.invalid`) and on its own direct calls.

**Required deployment posture:** `AXONFLOW_TRUST_IDENTITY_HEADERS=true` on the AxonFlow **agent**. The override writes are scoped to an individual user, and without a trusted per-user identity the platform refuses them for identity before it answers the retirement, which this suite reports as a failure with the remediation. Only enable it when every hop that can reach the agent asserts end-user identity from a validated source.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/create-override/test.sh
```

Before v11.0.0 this suite asserted a 403 on a critical-risk policy; on v11.0.0 no override is created for any policy.
