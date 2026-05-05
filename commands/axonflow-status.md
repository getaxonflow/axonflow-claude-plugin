---
description: Show your AxonFlow tenant_id (needed for Stripe Pro checkout), endpoint, tier (Free vs Pro), and Pro license expiry date
---

Print a one-screen status for the AxonFlow plugin so the user can find their `tenant_id` (required to fill in the Stripe checkout custom field when upgrading to AxonFlow Pro), confirm whether the plugin is currently in Free or Pro tier mode, and see when the Pro license expires.

This command takes no arguments.

Run the plugin's `status.sh` helper using the `Bash` tool:

```
$CLAUDE_PLUGIN_ROOT/scripts/status.sh
```

The helper resolves the same way the runtime hooks do — `AXONFLOW_ENDPOINT` if set, otherwise the Community SaaS at `https://try.getaxonflow.com` — and reads `~/.config/axonflow/try-registration.json` (or `$AXONFLOW_CONFIG_DIR/try-registration.json` when set) for the `tenant_id`. Tier is computed from whether `AXONFLOW_LICENSE_TOKEN` env var or `~/.config/axonflow/license-token.json` resolves to a valid `AXON-`-prefixed token AND its JWT `exp` claim is in the future. Three tier-line shapes are possible:

- `tier=Pro (expires 2026-08-03, 90 days remaining)` — paid Pro tier active.
- `tier=Free (Pro expired 2026-02-04 — visit https://getaxonflow.com/pro to renew)` — token configured but its `exp` is in the past; plugin will not forward it. User must renew + re-run `/axonflow-login --token <new>`.
- `tier=Free (no Pro license configured)` — no token loaded.

Output is line-oriented (`OK  field=value`-style), so render it back to the user verbatim, then add:

> "Copy the `tenant_id` line above into the **'AxonFlow tenant ID'** custom field at Stripe checkout when you upgrade to Pro. If `tenant_id` is empty, run `/axonflow-recover <email>` to recover (or re-register by removing `~/.config/axonflow/try-registration.json` and reloading)."

If the tier line shows `Pro expired …`, recommend the user renew and run `/axonflow-login --token <new-token>` to overwrite the on-disk token.

If the helper exits non-zero, surface the `ERR …` line verbatim.

The token preview only ever shows the last 4 characters (`set (AXON-...XXXX)`) — the full bearer credential is never printed, since `/axonflow-status` output is the surface users are most likely to screen-share or paste into a support ticket. The script extracts the JWT `exp` claim for display only; signature validation is the platform's job.
