# user-token — runtime E2E

**Asserts** (axonflow-enterprise#2935, epic #2919), by driving the plugin's
real hook scripts (`pre-tool-check.sh` → `check_policy`,
`post-tool-audit.sh` → `audit_tool_call`) against a live AxonFlow agent and
reading the canonical `audit_logs` rows back from the platform DB — no mocks,
no stubs:

1. **Unconfigured (the common fleet state):** with no per-user token anywhere,
   governed rows are written and attribute exactly as before (`X-User-Email`
   label) — the plugin's behavior is byte-identical to pre-1.10.
2. **Validated identity (platform with enterprise#2929+):** with a REAL minted
   per-user token configured (env or 0600 `user-token.json`), governed rows on
   BOTH planes attribute to the **token's canonical email** — even when
   `AXONFLOW_USER_EMAIL` asserts a *different* address. The validated identity
   beats the forgeable label; that is the whole point of the token.
3. **Unhappy path (fail-closed):** a tampered token → the platform rejects the
   request (HTTP 401, JSON-RPC `-32001`) and `pre-tool-check.sh` surfaces a
   structured **deny** whose reason names the per-user token as the likely
   cause. Tool calls do NOT silently fall open on a bad credential.
4. **Cross-plane equivalence (#108):** a MALFORMED (non-empty, wire-unsafe)
   `AXONFLOW_USER_TOKEN` env var alongside a valid 0600 `user-token.json` —
   BOTH resolvers drop the junk env candidate and fall back to the file
   token: the hook plane's audit row attributes to the file token's validated
   email, AND the **real `.mcp.json` inline `headersHelper`** emits
   `X-User-Token` with the file token, which the live platform accepts
   (HTTP 200 on `tools/list`, where the garbage probe got 401). Pre-#108 the
   inline suppressed the file read whenever the env was non-empty, sending NO
   token on the MCP plane while the hook plane sent the file token.

Legs 2–4 need a platform that validates `X-User-Token`
(`authenticateMCPServerRequest` → `extractPerUserToken`, enterprise#2929). The
harness probes for that capability by presenting a garbage token: a pre-#2929
platform ignores the header (probe succeeds → legs 2–4 SKIP with a notice), a
post-#2929 enterprise platform rejects it.

**Trust-gate awareness (platform v9.9.0):** `session_id` and the
`X-User-Email` label ride `AXONFLOW_TRUST_IDENTITY_HEADERS`, which defaults
OFF. A gate-off platform still governs and audits every request but
attributes rows to the client-scoped identity (`mcp-client:<org>`, empty
`session_id`) — documented platform behavior, not a plugin fault. Using the
script's own leg names (`Leg 0`–`Leg 3` in the output): the harness detects
the gate state during Leg 0 and passes it on the client-scoped criterion; the
session-keyed per-user attribution assertions (Leg 1, and the hook half of
Leg 3 — "leg 3a") then SKIP with a notice, while the fail-closed Leg 2 and
the MCP-inline half of Leg 3 ("leg 3b") still run.

**Prereqs:** `jq`, `curl`, `psql`, `python3` on PATH; a live agent at
`$AXONFLOW_ENDPOINT` (default `http://localhost:8080`); an enterprise Basic
credential (`AXONFLOW_AUTH`, or `AXONFLOW_E2E_ENTERPRISE_AUTH`, or
`AXONFLOW_E2E_ORG_ID` + `AXONFLOW_E2E_LICENSE_KEY`); `AXONFLOW_E2E_DB_URL`
pointing at the platform DB. For the token legs, ONE of:

- `AXONFLOW_E2E_USER_TOKEN` + `AXONFLOW_E2E_USER_TOKEN_EMAIL` — a real token
  minted via the platform admin API
  (`POST /api/v1/admin/organizations/{org_id}/user-tokens`, enterprise#2930)
  and the email it was minted for; or
- `AXONFLOW_E2E_JWT_SECRET` — the agent's `JWT_SECRET`; the harness signs an
  HS256 token with the exact claims contract the mint API produces
  (`iss=axonflow-user-token-mint`, `email`, `role`, `org_id`, `jti`, `iat`,
  `exp`). The platform validates it for real — same signature check, same
  org binding, same revocation lookup — so this is the mint contract, not a
  mock. Requires `AXONFLOW_E2E_ORG_ID` (the org the Basic credential
  authenticates as).

Skips cleanly when any prereq is absent.

**Run (local stack):**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
AXONFLOW_E2E_ORG_ID=<org> AXONFLOW_E2E_LICENSE_KEY=AXON-... \
AXONFLOW_E2E_JWT_SECRET=<agent JWT_SECRET> \
AXONFLOW_E2E_DB_URL='postgres://axonflow:localdev123@localhost:5432/axonflow?sslmode=disable' \
  bash runtime-e2e/user-token/test.sh
```
