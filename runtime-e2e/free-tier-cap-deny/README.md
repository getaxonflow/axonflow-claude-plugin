# free-tier-cap-deny: runtime E2E

**Asserts**, by firing the plugin's real hook scripts (`scripts/pre-tool-check.sh` and `scripts/post-tool-audit.sh`) with Claude Code's hook JSON on stdin against a real local AxonFlow stack in Community SaaS mode, with no mocks, stubs or recorded responses:

1. **Under the Free per-minute limit the hooks govern as usual.** A freshly registered Free tenant's first tool calls are allowed by a real `check_policy` decision.
2. **Over the limit, the pre hook blocks the tool call and names the limit** (a `hookSpecificOutput` object with `permissionDecision: "deny"` on stdout, exit 0). The upgrade prompt still prints on stderr (`[AxonFlow] Upgrade: ...`), and the back-off is stamped: `throttle-until` holds a future deadline and the limit's type, not the 401 credential pause.
3. **The post hook's own check over the limit raises a governance alert** that tells the agent not to use output it could not check, instead of passing the output.
4. **While the back-off holds, the pre hook keeps blocking and the post hook keeps alerting.**

The limit is reached by the hooks' own MCP calls. Before the fix this leg ships with, both hooks read the limit's answer as an allow, so tool calls over the limit ran ungoverned with nothing shown.

## The platform side

getaxonflow/axonflow-enterprise#4261 is what makes the cap a correct per-minute HTTP 429 with `Retry-After`. Until it lands, the MCP route answers the per-minute limit with a JSON-RPC result flagged `isError` that carries the daily-quota envelope. The hooks block on either answer, and this leg asserts the block either way: it prints the answer it saw on an `OBSERVED:` line without depending on it.

## Method

Claude Code runs each hook as a subprocess, passes the hook JSON on stdin (`{"tool_name": "Bash", "tool_input": {"command": ...}, "session_id": ...}`, with `tool_response` added for PostToolUse), and blocks on a `hookSpecificOutput` object with `permissionDecision: "deny"` on stdout, exit 0. This leg runs the shipped scripts exactly that way, headless: it does not launch Claude Code. The stack, the tenant and every platform answer are real.

## Prerequisites

`bash`, `curl` and `jq` on PATH, and a local stack in Community SaaS mode:

    docker compose -f docker-compose.yml -f docker-compose.community-saas.yml up -d

The leg skips cleanly when the endpoint is unreachable, or when `/api/v1/register` answers 404 (a stack that is not in Community SaaS mode). Each run registers one tenant, and the registration route is rate limited per IP.

## Run

    AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/free-tier-cap-deny/test.sh

`AXONFLOW_E2E_EVIDENCE_DIR` keeps each hook call's stdin, stdout, stderr and exit code (default: a new temporary directory, printed at the start). `AXONFLOW_E2E_CAP_MAX_CALLS` bounds the calls made to reach the limit (default 60). The tenant's secret is never printed or written to disk.
