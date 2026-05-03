# create-override — runtime E2E

**Asserts:** Claude Code dispatches `mcp__plugin_axonflow_axonflow__create_override` through its MCP runtime against the live stack. Asks for an override on `sys_sqli_admin_bypass` which has `allow_override=false`; the platform returns 403 — that's the runtime-path success criterion (agent picked the tool, runtime dispatched, platform answered, agent surfaced the rejection). Happy-path lives in `../governance-lifecycle/test.sh` (requires evaluation+ license to seed an override-able policy).

**Prereqs:** `claude` CLI on PATH and authenticated; `jq`; live AxonFlow stack reachable at `$AXONFLOW_ENDPOINT`.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/create-override/test.sh
```
