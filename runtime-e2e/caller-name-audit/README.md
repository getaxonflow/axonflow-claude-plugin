# caller-name-audit — runtime E2E

**Asserts** (axonflow-enterprise#2912, sub-issue of epic #2905), by driving
the plugin's real hook scripts (`pre-tool-check.sh`, `post-tool-audit.sh`)
against a live AxonFlow agent and reading the canonical `audit_logs` rows back
from the platform DB — no mocks, no stubs:

Both `audit_tool_call` send sites in this plugin now send `caller_name:
"claude_code"` instead of the misleadingly-named `tool_type: "claude_code"`
(`tool_type` identified WHICH CLIENT called, not a tool classification):

1. **pre-tool-check.sh's blocked-call audit POST** — fires when `check_policy`
   denies a tool call (the "record the blocked attempt" branch). The
   resulting row carries `policy_details->>'caller_name' = 'claude_code'`.
2. **post-tool-audit.sh's main PostToolUse audit POST** — fires on every
   executed tool call. Same assertion.
3. **No row carries `policy_details.tool_type`** — the platform
   (axonflow-enterprise#2953) still accepts `tool_type` as a legacy fallback,
   but this plugin no longer sends it, and the platform no longer writes it
   for new rows.

**Prereqs:** `jq`, `curl`, `psql` on PATH; a live agent at `$AXONFLOW_ENDPOINT`
(default `http://localhost:8080`); an enterprise Basic credential
(`AXONFLOW_AUTH`, or `AXONFLOW_E2E_ENTERPRISE_AUTH`, or
`AXONFLOW_E2E_ORG_ID` + `AXONFLOW_E2E_LICENSE_KEY`); and `AXONFLOW_E2E_DB_URL`
pointing at the platform DB (needed to inspect `policy_details`, which the
audit-search API does not expose key-by-key). Skips cleanly when any prereq
is absent, or when the agent predates axonflow-enterprise#2953 (in which case
the assertions legitimately FAIL rather than SKIP — a caller should upgrade
the platform, not silently pass).

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
AXONFLOW_E2E_ORG_ID=<org> AXONFLOW_E2E_LICENSE_KEY=AXON-... \
AXONFLOW_E2E_DB_URL='postgres://axonflow:localdev123@localhost:5432/axonflow?sslmode=disable' \
  bash runtime-e2e/caller-name-audit/test.sh
```
