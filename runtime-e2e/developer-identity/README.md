# developer-identity — runtime E2E

**Asserts** (issues #2753/#2754; identity-absent hardening
axonflow-enterprise#2836), by driving the plugin's real hook scripts
(`pre-tool-check.sh` → `check_policy`, `post-tool-audit.sh` →
`audit_tool_call`) against a live AxonFlow agent and reading the canonical
`audit_logs` rows back from the platform DB — no mocks, no stubs:

1. **env identity:** with `AXONFLOW_USER_EMAIL` set and a `session_id` in the
   hook stdin, rows on BOTH planes carry `user_email = <the developer>` AND
   `session_id = <the session>` in their first-class columns.
2. **identity-ABSENT** (the unconfigured-fleet state — no env var, no git
   identity, non-repo cwd): governed rows are still written, they degrade to
   the client-scoped id (never blank/NULL, no leaked identity), and the hook
   fires the one-line stderr diagnostic explaining why.
3. **git fallback:** with only a git `user.email` configured, the hardened
   resolution carries the git identity through both planes.

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
