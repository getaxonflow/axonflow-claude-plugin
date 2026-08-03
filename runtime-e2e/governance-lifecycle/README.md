# governance-lifecycle — runtime integration test

**Asserts:** Claude Code chains multiple W2 tools in a single conversation. Read-only subset (no license required): agent invokes both `search_audit_events` AND `list_overrides` in one prompt, both succeed, and the agent reports a combined result. Full lifecycle (create → list → explain → revoke → list) requires an evaluation+ license to seed an override-able policy; gated on `AXONFLOW_LICENSE` env var.

**Why this exists alongside the per-feature tests:** per-feature tests prove each tool dispatches in isolation. This test proves the features cohere — multi-tool sessions don't break, tool results don't confuse the agent into stopping the chain.

**Prereqs:** `claude` CLI on PATH and authenticated; `jq`; live AxonFlow stack reachable at `$AXONFLOW_ENDPOINT`. For the full lifecycle: `AXONFLOW_LICENSE` set.

**Required deployment posture:** the override endpoints are scoped to an individual user, so the AxonFlow **agent** must be forwarding a per-user identity. On a default deployment it is not: `AXONFLOW_TRUST_IDENTITY_HEADERS` defaults to **off** (since 9.9.0) and the agent strips `X-User-Email`, so `create_override` returns 401 and this test **fails** with the remediation printed (it used to skip silently and report green — #3062).

```bash
AXONFLOW_TRUST_IDENTITY_HEADERS=true   # on the AGENT, then restart it
```

Only enable it when every hop that can reach the agent asserts end-user identity from a validated source — see `docs/security/identity-header-trust.md` in axonflow-enterprise.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/governance-lifecycle/test.sh
```
