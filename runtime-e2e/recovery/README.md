# recovery — runtime E2E

**Asserts:** the plugin's `/axonflow-recover` and `/axonflow-recover-verify` slash commands drive the platform's free-tier email recovery flow end-to-end:

1. `recover.sh <email>` POSTs `/api/v1/recover` and gets the platform's 202 anti-enumeration response.
2. The agent's noop email sender appends a `to=<email> link=...?token=<hex>` line to the capture file.
3. `recover-verify.sh <token>` POSTs the magic-link token to `/api/v1/recover/verify`.
4. On success the plugin atomically writes the new `{tenant_id, secret, secret_prefix, expires_at, endpoint, email, note}` bundle to `~/.config/axonflow/try-registration.json` with mode 0600 inside a 0700 directory.
5. Replay of the same token returns HTTP 401 (consumed-once invariant).

**Prereqs:**
- `jq`, `curl`, the plugin's own scripts.
- A live AxonFlow agent in **community-saas mode** at `$AGENT_URL` (default `http://localhost:8080`) with PR #1850 applied (the recovery handler).
- The agent container must export `AXONFLOW_RECOVERY_TEST_CAPTURE_FILE=/path/to/captures.txt` AND that path must be mounted into the host so this script can read it. See `axonflow-enterprise/runtime-e2e/recovery/README.md` for the docker-compose overlay.

The test SKIPs cleanly (exit 0) when the agent is unreachable, the agent is on the wrong port (some other service replying to `/health`), or the agent's `/api/v1/register` doesn't return JSON — so this test is safe to run on a developer laptop or CI runner without a stack.

The test stashes any pre-existing `~/.config/axonflow/try-registration.json` and restores it on exit so it never trashes the developer's own credentials.

The agent's `/api/v1/register` and `/api/v1/recover` share an in-memory IP-based rate limiter (5 calls/hour/IP). Because dev laptops typically run this test multiple times against the same `localhost` agent, the test spoofs a unique `X-Forwarded-For` per run via the `TEST_XFF` variable (set automatically from PID + epoch) and threads it through `recover.sh` via the test-only `AXONFLOW_RECOVER_TEST_FORWARDED_FOR` env hook. Production callers never set that env var; if they did, a real upstream proxy would overwrite the header before it reached the agent.

**Run:**
```bash
AGENT_URL=http://localhost:8080 \
AXONFLOW_RECOVERY_TEST_CAPTURE_FILE=/tmp/axonflow-recovery-captures.txt \
  bash runtime-e2e/recovery/test.sh
```

Expected exit code: 0 on pass or skip; 1 on any assertion failure.
