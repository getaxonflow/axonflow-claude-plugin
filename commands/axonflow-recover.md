---
description: Request an AxonFlow Community-SaaS recovery magic link sent to your email (free tier, anti-enumeration always returns 202)
argument-hint: <email>
---

Request a magic-link email so an AxonFlow Community-SaaS tenant bound to the given email can recover fresh credentials. The platform always returns 202 with a generic message regardless of whether the email exists — this is intentional anti-enumeration behavior.

Argument: $ARGUMENTS

Parse the argument as `<email>`. If missing or doesn't contain `@`, ask the user for a valid email.

Then run the plugin's `recover.sh` helper using the `Bash` tool. The helper POSTs to the agent's `/api/v1/recover` endpoint (no auth required — recovery is the path for users who lost their auth) and surfaces the platform's 202 message.

```
$CLAUDE_PLUGIN_ROOT/scripts/recover.sh '<email>'
```

The helper resolves the AxonFlow endpoint the same way the runtime hooks do: `AXONFLOW_ENDPOINT` if set, otherwise the Community SaaS at `https://try.getaxonflow.com`.

Surface the script's `OK …` line verbatim, then add:

> "If a tenant is bound to that email you'll receive a magic link within a few minutes (check spam too). The link expires in 15 minutes. When you receive it, copy the `token=…` value from the URL and run `/axonflow-recover-verify <token>` to complete recovery."

If the helper exits non-zero (network failure, IP rate-limit), surface the `ERR …` line verbatim.
