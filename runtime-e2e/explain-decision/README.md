# explain-decision — runtime E2E

**Asserts:** Claude Code dispatches `mcp__plugin_axonflow_axonflow__explain_decision` through its MCP runtime against a live AxonFlow stack with a fabricated `decision_id` (community mode has no policy that emits real ones). The platform returns a structured "not found" response, the agent consumes it, and emits a `SMOKE_RESULT:` marker downstream. This proves the runtime path; happy-path with a real decision_id lives in `../governance-lifecycle/test.sh` (license-gated).

**Prereqs:** `claude` CLI on PATH and authenticated; `jq`; live AxonFlow stack reachable at `$AXONFLOW_ENDPOINT` (default `http://localhost:8080`).

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/explain-decision/test.sh
```
