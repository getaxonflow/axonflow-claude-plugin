# Runtime E2E — skill prefers the local status path

Verifies that the `axonflow-status` skill steers Claude to invoke the
LOCAL `scripts/status.sh` BEFORE making any agent round-trip when the
operator asks "what's my AxonFlow tenant ID?".

## What this test exercises

End-to-end against the **real `claude` CLI** with the plugin loaded
against a **real AxonFlow agent** (defaults to
`https://try.getaxonflow.com` Community SaaS when nothing else is
configured). Per HARD RULE #0
(`feedback_runtime_proof_is_definition_of_done.md`) — the bytes the
agent reasons against, the bytes it answers from, and the bytes the
host CLI captures in `--output-format stream-json` are all real.

## Why this test exists

The `axonflow-status` SKILL.md was previously written so step 1
preferred the agent-side MCP tool `axonflow_get_tenant_id` — every
"what's my tenant ID?" query then required an HTTP round-trip even
though the local `scripts/status.sh` could answer it from persisted
state. This SKILL change flipped the preference; this test locks the
behaviour change in.

## Steps

1. Spawn the real `claude` CLI with `--plugin-dir` pointing at the
   plugin source tree, `--output-format stream-json`, and the prompt
   "What's my AxonFlow tenant ID? Answer just by reading my local
   AxonFlow plugin state — don't make a network call to the AxonFlow
   agent if you can avoid it."
2. Parse the stream-json output, find the FIRST `tool_use` block in
   the assistant stream.
3. Assert `tool.name == "Bash"` and `tool.input.command` references
   `scripts/status.sh`. Any MCP tool call (`mcp__axonflow__*`) as the
   first action means the skill flip didn't stick.
4. Assert the final result text mentions a `tenant_id` value (the
   skill's step 3 says to surface it to the user).

## Skip conditions

- `claude` CLI not on PATH → SKIP.
- `jq` not on PATH → SKIP.
- `${AXONFLOW_ENDPOINT}/health` not reachable → SKIP (offline / firewalled CI).

## Usage

```bash
# Default (Community SaaS):
bash runtime-e2e/skill-prefers-local-status/test.sh

# Self-hosted:
AXONFLOW_ENDPOINT=http://localhost:8080 \
  AXONFLOW_AUTH=$(printf '%s:%s' demo-client demo-secret | base64) \
  bash runtime-e2e/skill-prefers-local-status/test.sh
```

Evidence under `runtime-e2e/skill-prefers-local-status/EVIDENCE/<utc-ts>/`:

- `claude_stream.jsonl` — full stream-json captured from the host CLI
- `first_tool.json` — `{ name, input }` of the first tool the agent invoked
- `result_text.txt` — the agent's final answer text
- `summary.txt` — top-line PASS / FAIL line

## Cross-references

- Skill file: `skills/axonflow-status/SKILL.md` — the document under test
- Content assertion (always runs): `tests/test-skill-status-prefers-local.sh`
- Doctrine: `feedback_runtime_proof_is_definition_of_done.md`
- Predecessor PR (#64) that introduced the round-trip-preferred wording
