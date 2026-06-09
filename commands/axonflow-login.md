---
description: Save AxonFlow credentials locally — a Pro license token (AXON-...) for X-License-Token, or a self-hosted/Enterprise Basic-auth credential for the MCP connection
argument-hint: <AXON-license-token> | --self-hosted <org_id> <license_key>
---

Persist an AxonFlow credential to the plugin's local config. Two modes, selected by the argument shape:

**Mode A — Pro license token (default).** `$ARGUMENTS` is an `AXON-...` token. Persist it so every subsequent governed tool call carries it as the `X-License-Token` HTTP header. The agent's plugin-claim middleware then enriches the request context with Pro-tier metadata (extended retention, higher daily quotas, etc.).

**Mode B — self-hosted / Enterprise Basic-auth credential.** `$ARGUMENTS` begins with `--self-hosted` followed by `<org_id> <license_key>`. Persist a base64 Basic-auth credential to `~/.config/axonflow/self-hosted-auth.json` so BOTH the MCP `headersHelper` and the per-call hooks can authenticate to your self-hosted/Enterprise agent even when `AXONFLOW_AUTH` is not exported into every subprocess (the gap behind axonflow-claude-plugin#94). This mirrors the durable on-disk credential Community-SaaS already caches in `try-registration.json`. **Precedence: the `AXONFLOW_AUTH` env var always wins; this file is the fallback.** Run:

```
$CLAUDE_PLUGIN_ROOT/scripts/login.sh --self-hosted '<org_id>' '<license_key>'
```

Surface the helper's `OK …` / `ERR …` line verbatim. The credential takes effect on the next governed tool call (hooks) and on the next Claude Code session start (MCP `headersHelper`).

---

For Mode A, parse the argument as `<token>`. If missing, ask the user for it. Tokens issued by the AxonFlow billing webhook always start with `AXON-` and are at least 32 characters long. If the input doesn't look like that, refuse and ask the user to paste the token from their welcome email.

Then run the plugin's `login.sh` helper using the `Bash` tool. The helper persists the token to `~/.config/axonflow/license-token.json` (mode 0600 inside a 0700 directory) and validates the AXON- prefix locally before writing.

```
$CLAUDE_PLUGIN_ROOT/scripts/login.sh '<the AXON- token>'
```

The helper writes a single-line `OK …` (success) or `ERR …` (failure) to stdout. Surface the line verbatim, then add the operator hint:

> "Pro tier license saved. Restart any open Claude Code session for the new token to take effect on the MCP server connection (the plugin's `headersHelper` only fires at session start; the per-call `pre-tool-check` hook picks the token up immediately on its next invocation)."

If the user prefers env-var configuration, tell them: "Alternatively, set `AXONFLOW_LICENSE_TOKEN=<your AXON- token>` in your shell profile — the env var takes precedence over the saved file and avoids the on-disk credential entirely."
