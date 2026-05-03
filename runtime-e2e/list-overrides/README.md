# list-overrides — runtime E2E

**Asserts:** Claude Code dispatches `mcp__plugin_axonflow_axonflow__list_overrides` through its MCP runtime against the live stack. Empty-state success path: in community mode the response is `{overrides: [], count: 0}`. Agent reports the count downstream of the result via `SMOKE_RESULT:` marker.

**Prereqs:** `claude` CLI on PATH and authenticated; `jq`; live AxonFlow stack reachable at `$AXONFLOW_ENDPOINT`.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/list-overrides/test.sh
```
