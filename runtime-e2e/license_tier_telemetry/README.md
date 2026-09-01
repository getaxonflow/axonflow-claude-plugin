# Runtime E2E - `license_tier` on the usage heartbeat (#3619)

The heartbeat now reports the licence tier the **platform** says it is running under, read from the `tier` key of the `/health` response `scripts/telemetry-ping.sh` already fetches. This test proves that field on the wire, through the shipped script rather than a reimplementation of it.

## Prereqs

- `bash`, `jq`, `curl`, `python3` on `$PATH`
- Stage 2 only: a reachable AxonFlow agent. Defaults to `http://localhost:8080`; override with `AXONFLOW_ENDPOINT`. Start one via `axonflow-enterprise/scripts/setup-e2e-testing.sh`.

## What it asserts

**Stage 1a - behaviour matrix** (`tests/telemetry-license-tier/run.sh`, always runs). Every tier the platform can answer with reaches the wire byte-for-byte unchanged, including the lowercase `community` default, the transient `starting`, and a tier this build has never heard of. Every way the probe can fail - unreachable, 4xx, 5xx, malformed, empty, wrong-typed, absent, over-long, slower than the probe budget - omits the key entirely and leaves the heartbeat delivered, the exit code 0, and both streams silent. One case pins `license_tier`, `deployment_mode` and `endpoint_type` to three different values so no pair of them can be quietly conflated, and one pins the probe at exactly one `GET /health` per heartbeat, because a second request would make this a new data collection rather than a new field.

**Stage 1b - mutation gate** (`tests/telemetry-license-tier/mutation_gate.sh`, always runs). Plants a defect in a copy of the shipped script for each property above - field never sent, omission replaced by a literal `"unknown"`, string-type guard removed, `--fail` dropped, length cap raised, client-side normalisation introduced, a second `/health` request - and requires the matrix to go red for each. A neutral rewrite that changes no behaviour is planted last and must **survive**, which is what separates a real kill from a harness that is red for unrelated reasons.

**Stage 2 - real agent** (skipped when none is reachable). Reads the tier a live agent reports about itself, drives the real heartbeat against that same agent, and requires the captured ping to carry that exact value. The expected value is read from the agent at runtime rather than hard-coded, so the assertion is equally valid against a community stack and an enterprise-licensed one. If the agent reports no tier at all, the test asserts the key is **omitted** instead of skipping, so an older platform still exercises the fail-open path.

The heartbeat's destination is redirected to a local receiver so a test run never writes a row into production analytics. The agent whose tier is under test is the real one.

## Run

```bash
./runtime-e2e/license_tier_telemetry/test.sh
AXONFLOW_ENDPOINT=http://localhost:8080 ./runtime-e2e/license_tier_telemetry/test.sh
```
