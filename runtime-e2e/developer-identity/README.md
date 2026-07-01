# developer-identity — runtime E2E

**Asserts:** with `AXONFLOW_USER_EMAIL` set and a `session_id` in the hook stdin,
the plugin's real hook scripts (`pre-tool-check.sh` → `check_policy`,
`post-tool-audit.sh` → `audit_tool_call`) forward `X-User-Email` + `X-Session-Id`
to a live AxonFlow agent, and the resulting canonical `audit_logs` rows on BOTH
planes carry `user_email = <the developer>` AND `session_id = <the session>` in
their first-class columns (issue #2753/#2754). Verified by reading the rows back
from the platform DB — no mocks, no stubs; the agent + orchestrator are the real
stack.

**Prereqs:** `jq`, `curl`, `psql` on PATH; a live agent at `$AXONFLOW_ENDPOINT`
(default `http://localhost:8080`); an enterprise Basic credential
(`AXONFLOW_AUTH`, or `AXONFLOW_E2E_ENTERPRISE_AUTH`, or
`AXONFLOW_E2E_ORG_ID` + `AXONFLOW_E2E_LICENSE_KEY`); and `AXONFLOW_E2E_DB_URL`
pointing at the platform DB (needed because the audit-search API does not yet
expose the new `session_id` column). Skips cleanly when any prereq is absent.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
AXONFLOW_E2E_ORG_ID=<org> AXONFLOW_E2E_LICENSE_KEY=AXON-... \
AXONFLOW_E2E_DB_URL='postgres://axonflow:localdev123@localhost:5432/axonflow?sslmode=disable' \
  bash runtime-e2e/developer-identity/test.sh
```
