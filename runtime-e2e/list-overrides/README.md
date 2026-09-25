# list-overrides — runtime E2E

**Asserts:** `list_overrides` is an unchanged read on AxonFlow v11.0.0. The MCP and REST counts agree; Claude Code invokes `mcp__plugin_axonflow_axonflow__list_overrides`, its tool_result is a successful read carrying a count, and the agent's final message reports the platform's count. No override is seeded: none can be created on v11.0.0.

**Prereqs:** `claude` CLI on PATH and authenticated; `jq`; a live AxonFlow v11.0.0 stack reachable at `$AXONFLOW_ENDPOINT` (never production: nothing here needs it). The suite presents `X-User-Email` through the plugin's MCP headersHelper (`AXONFLOW_USER_EMAIL`, default `claude-runtime-e2e@axonflow-test.invalid`) and on its own direct calls.

**Required deployment posture:** `AXONFLOW_TRUST_IDENTITY_HEADERS=true` on the AxonFlow **agent**. The override writes are scoped to an individual user, and without a trusted per-user identity the platform refuses them for identity before it answers the retirement, which this suite reports as a failure with the remediation. Only enable it when every hop that can reach the agent asserts end-user identity from a validated source.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/list-overrides/test.sh
```
