# mcp-self-hosted-auth-fallback (runtime E2E)

Regression for **axonflow-claude-plugin#94** — MCP `tools/call` 401'd on
self-hosted/Enterprise while the per-call hooks governed fine.

## Why

The inline `.mcp.json` `headersHelper` fell back to the Community-SaaS
`try-registration.json` regardless of endpoint. With `AXONFLOW_AUTH` unset and a
stale `cs_<uuid>` registration on disk, it sent that credential to the
Enterprise agent, which rejected it (`invalid license key prefix (expected
AXON-)`) → HTTP 401 → `/mcp` "axonflow failed". The hooks never used the cs_
credential on an Enterprise endpoint, so they kept working — the exact asymmetry
reported. The existing `self-hosted-enterprise-auth` lane always exported a real
`AXONFLOW_AUTH`, so it could not catch this.

## Asserts

- **Part A:** with a durable `self-hosted-auth.json` on disk and `AXONFLOW_AUTH`
  UNSET (plus a stale cs_ registration as a trap), `/mcp` connects and the
  `check_policy` MCP tool **actually executes** — the helper used the
  self-hosted credential, not cs_.
- **Part B:** with no self-hosted credential and `AXONFLOW_AUTH` still unset, the
  connection fails **closed** — it must NOT silently authenticate as the stale
  cs_ tenant. When `AXONFLOW_E2E_AGENT_CONTAINER` is set, also asserts no cs_
  auth attempt reached the agent.

Hermetic via `AXONFLOW_CONFIG_DIR` — the user's real `~/.config/axonflow` is
never touched. Unit-level coverage lives in `tests/test-mcp-headers.sh`.

## Prereqs / run

```bash
export AXONFLOW_ENDPOINT=http://localhost:8080
export AXONFLOW_E2E_ORG_ID=<org>            # e.g. bukuwarung-eval
export AXONFLOW_E2E_LICENSE_KEY=<AXON-...>   # real license key
# optional, strengthens Part B:
export AXONFLOW_E2E_AGENT_CONTAINER=axonflow-install-axonflow-agent-1
./test.sh
```

Skips cleanly if `claude`/`jq`/the stack/a real license is unavailable.
