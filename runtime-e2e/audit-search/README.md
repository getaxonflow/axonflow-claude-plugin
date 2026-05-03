# audit-search — runtime E2E

**Asserts:** Claude Code loads the plugin via `claude --plugin-dir`, Claude picks the `mcp__plugin_axonflow_axonflow__search_audit_events` MCP tool from a natural-language prompt, the runtime dispatches the JSON-RPC tools/call against the live MCP server, and the response is a non-error `{entries: [...], total: N}` payload that the agent consumes and emits a `SMOKE_RESULT:` marker downstream of.

**Prereqs:** `claude` CLI on PATH and authenticated (OAuth or `ANTHROPIC_API_KEY`); `jq`; live AxonFlow stack reachable at `$AXONFLOW_ENDPOINT` (default `http://localhost:8080`).

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
AXONFLOW_CLIENT_ID=demo-client \
AXONFLOW_CLIENT_SECRET=demo-secret \
  bash runtime-e2e/audit-search/test.sh
```
