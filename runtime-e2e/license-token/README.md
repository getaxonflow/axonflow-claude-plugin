# license-token — runtime E2E

**Asserts:** the plugin sends the user's paid-tier AxonFlow license token as the `X-License-Token` HTTP header on every governed agent request, in three resolution modes:

1. `AXONFLOW_LICENSE_TOKEN` env var set → header on the wire
2. `~/.config/axonflow/license-token.json` written by `/axonflow-login` → header on the wire
3. No token configured → header absent (free tier — middleware passes through)

Plus an env-precedence assertion (env wins over file) and the mode-clarity stderr canary `Pro tier active` is emitted when a token is configured.

The wire-level assertion is made via a tiny Python `http.server` capture proxy: every inbound request's headers + body get appended to a JSONL file, replies are a fixed MCP allow-shape response. The `pre-tool-check.sh` hook then runs against the proxy and we assert what landed on the wire.

A 5th assertion (live PluginClaimMiddleware accepts a real AXON- token at the agent) runs only if `AGENT_URL` and `TEST_LICENSE_TOKEN` are both set; otherwise SKIPped cleanly.

**Prereqs:** `python3`, `jq`, `curl`, the plugin's own scripts. No live agent required for tests 1-4.

**Run:**
```bash
bash runtime-e2e/license-token/test.sh
```

To exercise the live-agent assertion (test 5):
```bash
AGENT_URL=http://localhost:8080 \
TEST_LICENSE_TOKEN="AXON-..." \
  bash runtime-e2e/license-token/test.sh
```
