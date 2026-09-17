# hook-failure-posture: runtime E2E

**Asserts**, by firing the plugin's real hook scripts (`scripts/pre-tool-check.sh` and `scripts/post-tool-audit.sh`) with the hook JSON Claude Code sends, against a real AxonFlow stack and against an endpoint nothing listens on, with no mocks or stubs:

1. **The platform decides.** An allowed command runs (exit 0, nothing on stdout); a destructive command is denied (`permissionDecision: deny`, `AxonFlow policy violation`).
2. **No answer, `AXONFLOW_FAIL_MODE` unset.** The pre hook lets the tool call run and puts the `GOVERNANCE UNAVAILABLE` notice in the hook JSON's `systemMessage`, which Claude Code shows the user; the post hook passes the output with the notice and no alert.
3. **No answer, `AXONFLOW_FAIL_MODE=closed`.** The pre hook denies, naming the switch; the post hook raises the governance alert (`additionalContext`) that tells Claude not to use the output.
4. **The switches never loosen a decision.** A deny under `AXONFLOW_FAIL_MODE=open` and `AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1` is still denied.
5. **A live 401 from the agent.** The pre hook denies with the platform's words and stamps the `auth_failure` cooldown; the next call is denied by the cooldown without a request, naming the seconds left and the stamp file, even with the break-glass set; `AXONFLOW_FAIL_MODE=open` does not loosen it; with `AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1` the same `-32001` 401 runs, names the switch in `systemMessage` and stamps nothing; the post hook raises the governance alert.

## The live 401, and its side effect

A community AxonFlow v11.0.0 agent checks no client secret: a client id it has admitted gets a decision with any secret. Its one 401 is the MCP server's answer to a client id the organization has not admitted, once the organization has admitted its service-principal ceiling (5 on the community edition): `401 {"jsonrpc":"2.0","error":{"code":-32001,"message":"Authentication required"}}`, where the REST routes answer the same refusal `402 ERR_TIER_LIMIT_SERVICE_PRINCIPAL` (a platform defect: getaxonflow/axonflow-enterprise#4249, comment 5682255301).

Leg 5 therefore sends one request as this suite's own client (no credential), which keeps that client admitted, then new client ids until the MCP server refuses one: at most 5 requests. **On a community stack below its ceiling, those requests admit new client ids, and a later suite that presents a client id the organization has not yet admitted is refused.** Run it on a stack you can reset, or last.

## What this suite cannot reach

A credential the platform rejects as wrong (an Enterprise or Community SaaS stack), a request limit without the Free-tier envelope (429), a server error (5xx) and a 4xx without a decision body are not produced here: a community agent checks no secret, and nothing makes it answer 429 or 5xx on demand. Those rows are asserted against the hooks in `tests/test-hooks.sh`, through its local test server. The Free-tier limit is `free-tier-cap-deny` (a Community SaaS stack).

## Method

Claude Code runs each hook as a subprocess, passes the hook JSON on stdin, and reads its answer from stdout on exit 0. This suite runs the shipped scripts exactly that way, headless: it does not launch Claude Code. The JSON is the shape Claude Code sends, captured from a real session (`tests/fixtures/claude-code-hook-json/`, provenance in its README). That a `systemMessage` notice is what the user sees, and stderr on exit 0 is not, was established in that same real session.

Production Community SaaS is refused as a target (`runtime_e2e_refuse_production`): with `AXONFLOW_ENDPOINT` at `https://try.getaxonflow.com` the suite SKIPs unless `AXONFLOW_E2E_ALLOW_PRODUCTION=1`.

## Run

    AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/hook-failure-posture/test.sh

`AXONFLOW_E2E_EVIDENCE_DIR` keeps each hook call's stdin, stdout, stderr and exit code (default: a new temporary directory, printed at the start). Each hook runs with a sandboxed `HOME`, `XDG_CACHE_HOME` and `AXONFLOW_CONFIG_DIR` under that directory, with telemetry and the version check off. The suite skips cleanly when `curl`, `jq` or `python3` is missing or the endpoint is unreachable.
