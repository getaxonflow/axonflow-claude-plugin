---
description: Save a paid AxonFlow Pro license token (AXON-...) so the plugin sends it as X-License-Token on every governed agent request
argument-hint: <AXON-license-token>
---

Persist a paid AxonFlow Pro license token to the plugin's local config so every subsequent governed tool call carries it as the `X-License-Token` HTTP header. The agent's plugin-claim middleware then enriches the request context with Pro-tier metadata (extended retention, higher daily quotas, etc.).

Argument: $ARGUMENTS

Parse the argument as `<token>`. If missing, ask the user for it. Tokens issued by the AxonFlow billing webhook always start with `AXON-` and are at least 32 characters long. If the input doesn't look like that, refuse and ask the user to paste the token from their welcome email.

Then run the plugin's `login.sh` helper using the `Bash` tool. The helper persists the token to `~/.config/axonflow/license-token.json` (mode 0600 inside a 0700 directory) and validates the AXON- prefix locally before writing.

```
$CLAUDE_PLUGIN_ROOT/scripts/login.sh '<the AXON- token>'
```

The helper writes a single-line `OK …` (success) or `ERR …` (failure) to stdout. Surface the line verbatim, then add the operator hint:

> "Pro tier license saved. Restart any open Claude Code session for the new token to take effect on the MCP server connection (the plugin's `headersHelper` only fires at session start; the per-call `pre-tool-check` hook picks the token up immediately on its next invocation)."

If the user prefers env-var configuration, tell them: "Alternatively, set `AXONFLOW_LICENSE_TOKEN=<your AXON- token>` in your shell profile — the env var takes precedence over the saved file and avoids the on-disk credential entirely."
