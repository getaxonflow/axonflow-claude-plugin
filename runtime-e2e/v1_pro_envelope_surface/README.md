# Runtime E2E — V1 Plugin Pro envelope surface

Verifies that the Claude Code plugin's REAL upgrade-prompt helper surfaces
the V1 Plugin Pro structured upgrade envelope and honours the back-off
deadline carried in the response.

## What this test exercises

End-to-end against the **real plugin helper** (`scripts/upgrade-prompt.sh`)
running against a **real wire envelope** captured from the live agent at
`https://try.getaxonflow.com`. No fixtures and no recorded responses —
the envelope bytes that flow into `axonflow_handle_envelope_response`
are the bytes the agent emitted to the wire seconds earlier. Per
HARD RULE #0 (`feedback_runtime_proof_is_definition_of_done.md`).

Wire contract under test (locked in
`axonflow-enterprise/platform/agent/community_saas_ratelimit_response.go`):

- 429 daily-quota envelope:
  ```json
  {
    "error": "Daily request limit reached. Resets at midnight UTC.",
    "limit_type": "daily_quota",
    "tier": "Free",
    "limit": 200,
    "upgrade": {
      "tier": "Pro",
      "wording": "Daily limit reached on Free tier (200 events). Pro raises this to 2,000/day. Resets at midnight UTC.",
      "compare_url": "https://getaxonflow.com/pricing/",
      "buy_url": "https://buy.stripe.com/bJe28qbztcdVchjdkw8k800"
    }
  }
  ```
- Headers: `X-Axonflow-Tier-Limit: daily_quota`,
  `X-Axonflow-Upgrade-URL: https://getaxonflow.com/pricing/`,
  `Retry-After: <seconds-until-midnight-UTC>`.

## Why this drives the helper directly (not the full hook)

The agent emits the V1 Plugin Pro 429 envelope on
`/api/v1/audit/tool-call` (and other apiAuthMiddleware-routed paths).
The plugin's hooks call `/api/v1/mcp-server` which authenticates via
`authenticateMCPServerRequest` and currently does NOT route through
apiAuthMiddleware — so a Free-tier-capped tenant calling MCP gets a
JSON-RPC `-32001` result, not the 429 envelope.

The plugin code is correct (the helper handles both bare and JSON-RPC
wrapped envelopes per the dual-shape parser in
`scripts/upgrade-prompt.sh`). What's missing is server-side wiring of
the daily-cap check into MCP routing — outside this lane. See PR body
for the follow-up note.

## Steps

1. Register a synthetic Free-tier tenant via DB direct insert
   (`db_helpers.sh` from the sibling `axonflow-enterprise` checkout —
   same canonical pattern documented in
   `feedback_ecs_exec_apk_psql_for_db_access.md`). Direct insert avoids
   the per-IP 5/hr rate limit on `/api/v1/register` and gives the test
   a tenant scoped to a known `cs_e2e_claude_envelope_<ts>` prefix.
2. Seed `community_saas_daily_usage` to 200 (= the Free cap) for that
   tenant. Loop-to-trip-cap on prod hits a per-IP burst limiter (~20/min)
   long before the daily cap, and that limiter's response does NOT
   carry the V1 envelope (per
   `feedback_429_no_upgrade_hint_is_conversion_gap.md`); seeding the
   table directly puts the agent at the boundary on the next call.
3. Single `POST /api/v1/audit/tool-call` with the synthetic tenant's
   credentials → `apiAuthMiddleware` fires `writeRateLimitError` and
   the response body is the V1 envelope. Capture it.
4. Assert the wire envelope shape: `limit_type=daily_quota`,
   `tier=Free`, locked wording phrase `Pro raises this to 2,000/day`,
   canonical buy URL, and the three locked response headers
   (`X-Axonflow-Tier-Limit`, `X-Axonflow-Upgrade-URL`, `Retry-After`).
5. Source `scripts/upgrade-prompt.sh` and call
   `axonflow_handle_envelope_response` against the captured wire body +
   headers. Assert the helper:
   - returns 0 (envelope detected),
   - prints the locked wording + buy URL on stderr,
   - emits NO bytes on stdout (stdout is the hook protocol),
   - stamps `${XDG_CACHE_HOME}/axonflow/throttle-until` with a future-epoch
     deadline.
6. Assert `axonflow_throttle_active` returns 0 (gate active) so
   subsequent governed calls would short-circuit.
7. Re-invoke `axonflow_handle_envelope_response` and assert the wording
   is NOT re-emitted to stderr (once-per-UTC-day stamp).

The test redirects `XDG_CACHE_HOME` (which the helper honours) to a tmp
dir so the throttle file lands hermetically — `HOME` itself is left
intact so the AWS CLI continues to find the operator's credentials for
the ECS-exec preflight + DB seeding. The synthetic tenant + its
`daily_usage` row are dropped on cleanup.

## Skip conditions

- `curl`, `jq`, `aws`, `openssl`, `python3` missing → SKIP.
- `python3` `bcrypt` module not installed → SKIP (used by
  `db_register_tenant` to mint the bcrypt(cost=12) hash that matches
  `platform/agent/community_saas_register.go`).
- `${AGENT_URL}/health` not reachable → SKIP.
- Stack auto-discovery returned nothing (CI without IAM access) → SKIP.
- `db_helpers.sh` not present at `../axonflow-enterprise/runtime-e2e/v1_paid_tier_staging/lib/db_helpers.sh`
  → SKIP (sibling checkout required for the canonical helpers).

## Usage

```bash
AGENT_URL=https://try.getaxonflow.com bash runtime-e2e/v1_pro_envelope_surface/test.sh
```

Evidence is captured under
`runtime-e2e/v1_pro_envelope_surface/EVIDENCE/<utc-ts>/`:

- `register.json` — full register response
- `trip_loop.log` — request-number → http-code log proving the cap landed
- `envelope_body.json` / `envelope_body_pretty.json` — raw + pretty-printed
  envelope captured from the wire
- `envelope_headers.txt` — headers captured from the 429 response
- `helper_stdout.log` / `helper_stderr.log` — first helper invocation
- `helper_stderr_run2.log` — second helper invocation (once-per-day gate)
- `throttle-until.txt` — copy of the stamped back-off file
- `summary.txt` — top-line PASS / FAIL line

## Cross-references

- Wire contract: `axonflow-enterprise/platform/agent/community_saas_ratelimit_response.go`
- Server-side runtime proof: `axonflow-enterprise/runtime-e2e/v1_pro_envelope_pr1/`
- Doctrine: `feedback_runtime_proof_is_definition_of_done.md`
- Umbrella: `axonflow-enterprise#1958`, sub-issue `axonflow-enterprise#1962`
