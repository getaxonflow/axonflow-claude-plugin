---
description: Show your AxonFlow tenant_id (needed for Stripe Pro checkout), endpoint, and tier (Free vs Pro)
---

Print a one-screen status for the AxonFlow plugin so the user can find their `tenant_id` (required to fill in the Stripe checkout custom field when upgrading to AxonFlow Pro) and confirm whether the plugin is currently in Free or Pro tier mode.

This command takes no arguments.

Run the plugin's `status.sh` helper using the `Bash` tool:

```
$CLAUDE_PLUGIN_ROOT/scripts/status.sh
```

The helper resolves the same way the runtime hooks do — `AXONFLOW_ENDPOINT` if set, otherwise the Community SaaS at `https://try.getaxonflow.com` — and reads `~/.config/axonflow/try-registration.json` (or `$AXONFLOW_CONFIG_DIR/try-registration.json` when set) for the `tenant_id`. Tier is `Pro` if either `AXONFLOW_LICENSE_TOKEN` env var is set or `~/.config/axonflow/license-token.json` resolves to a valid `AXON-`-prefixed token; otherwise `Free`.

Output is line-oriented (`OK  field=value`-style), so render it back to the user verbatim, then add:

> "Copy the `tenant_id` line above into the **'AxonFlow tenant ID'** custom field at Stripe checkout when you upgrade to Pro. If `tenant_id` is empty, run `/axonflow-recover <email>` to recover (or re-register by removing `~/.config/axonflow/try-registration.json` and reloading)."

If the helper exits non-zero, surface the `ERR …` line verbatim.

The token preview only ever shows the last 4 characters (`set (AXON-...XXXX)`) — the full bearer credential is never printed, since `/axonflow-status` output is the surface users are most likely to screen-share or paste into a support ticket.
