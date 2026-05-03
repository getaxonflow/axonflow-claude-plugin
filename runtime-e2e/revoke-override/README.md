# revoke-override — runtime E2E

**Asserts:** Claude Code dispatches `mcp__plugin_axonflow_axonflow__delete_override` (the platform-side name for the revoke action) with a fabricated `override_id`. Platform returns 404; agent surfaces the not-found result via `SMOKE_RESULT:` marker. Happy-path revoke (real override created in the same session) lives in `../governance-lifecycle/test.sh`.

**Prereqs:** `claude` CLI on PATH and authenticated; `jq`; live AxonFlow stack reachable at `$AXONFLOW_ENDPOINT`.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/revoke-override/test.sh
```
