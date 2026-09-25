# revoke-override — runtime E2E

**Asserts:** `delete_override` answers the retired write on AxonFlow v11.0.0. Directly, MCP `delete_override` with `X-User-Email` answers a tool error beginning `LEGACY_POLICY_WRITE_FROZEN: ` and REST `DELETE /api/v1/overrides/<id>` answers HTTP 409. Through Claude Code, the agent invokes `mcp__plugin_axonflow_axonflow__delete_override` and receives that tool error, its final message reports `frozen: true`, and the `list_overrides` count does not move. No override is seeded: none can be created on v11.0.0.

**Prereqs:** `claude` CLI on PATH and authenticated; `jq`; a live AxonFlow v11.0.0 stack reachable at `$AXONFLOW_ENDPOINT` (never production: nothing here needs it). The suite presents `X-User-Email` through the plugin's MCP headersHelper (`AXONFLOW_USER_EMAIL`, default `claude-runtime-e2e@axonflow-test.invalid`) and on its own direct calls.

**Required deployment posture:** `AXONFLOW_TRUST_IDENTITY_HEADERS=true` on the AxonFlow **agent**. The override writes are scoped to an individual user, and without a trusted per-user identity the platform refuses them for identity before it answers the retirement, which this suite reports as a failure with the remediation. Only enable it when every hop that can reach the agent asserts end-user identity from a validated source.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/revoke-override/test.sh
```
