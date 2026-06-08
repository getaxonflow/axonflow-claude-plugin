# self-hosted-enterprise-auth (runtime E2E)

Drives the **real `claude` binary** with the plugin loaded via `--plugin-dir`
against a **real self-hosted / Enterprise (in-VPC) agent** using a **real
(non-demo) license** — the lane every other plugin test missed.

## Why

The rest of `runtime-e2e/` injects `demo-client:demo-secret` and always sets
`AXONFLOW_AUTH`, so it could never reproduce a real Enterprise user's failure:
the MCP server connection collapsing into OAuth discovery and the agent's
plaintext `404 page not found` (`/mcp` → "axonflow failed"), nor the
auth-missing fail-closed path.

## Asserts

- **Part A (auth present):** `/mcp` shows `axonflow connected`, the
  `check_policy` MCP tool is reachable over the governed connection, a benign
  op is allowed, a destructive op is blocked, and no raw OAuth-404 appears.
- **Part B (auth missing):** the tool call fails **closed** with an
  **actionable** reason naming `AXONFLOW_AUTH` (not a silent allow, not the
  bare OAuth-404).

## Prereqs / run

```bash
export AXONFLOW_ENDPOINT=http://localhost:8080        # your Enterprise agent
export AXONFLOW_E2E_ORG_ID=<org>                      # real org id
export AXONFLOW_E2E_LICENSE_KEY=<AXON-...>            # real license key
# or: export AXONFLOW_E2E_ENTERPRISE_AUTH=<base64(org:license)>
./test.sh
```

Skips cleanly if `claude`/`jq`/the stack/a real license is unavailable. It
**refuses to fall back to demo creds** — demo-client:demo-secret against the
hosted SaaS is not coverage for this path.
