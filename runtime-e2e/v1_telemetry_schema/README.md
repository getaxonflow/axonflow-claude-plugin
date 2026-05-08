# Runtime E2E — v1 telemetry-schema heartbeat (#2008)

Drives the plugin's `pre-tool-check.sh` hook against a real local
checkpoint server, captures the actual heartbeat payload off the wire,
and asserts the four v1-schema fields: `telemetry_type`,
`deployment_mode`, `endpoint_type`, `profile`.

This wrapper delegates to `tests/heartbeat-real-stack/run_real_stack.sh`
which is the canonical telemetry runtime-proof harness — it predates
the `runtime-e2e/` directory convention but exercises exactly the same
real-runtime path the gate is asking for.

## Prereqs

- `bash`, `jq`, `curl`, `python3` on `$PATH`

## Run

```bash
./runtime-e2e/v1_telemetry_schema/test.sh
```

The harness binds the receiver to a free 127.0.0.1 port, exercises a
cold-start (15 assertions including v1 field shape) and a warm-cache
(stamp-gate suppression) scenario, then exits non-zero on any failure.
