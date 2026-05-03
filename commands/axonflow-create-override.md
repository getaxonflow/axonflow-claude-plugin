---
description: Create a governed AxonFlow session override with mandatory justification (TTL clamped server-side; critical-risk policies blocked)
argument-hint: <policy-id> <static|dynamic> <reason>
---

Create a session override against an AxonFlow policy that would otherwise deny.

Arguments: $ARGUMENTS

Parse the arguments as `<policy_id> <policy_type> <reason...>`. If any are missing, ask the user for them — `policy_id`, `policy_type` (`static` or `dynamic`), and a free-text `override_reason` are all mandatory.

Then call the `create_override` MCP tool. The platform may return HTTP 403 if:

- The policy is critical-risk (no override permitted)
- The policy has `allow_override: false`

Surface the response's `id`, `expires_at`, and any `clamped` flag (meaning the requested TTL was clamped down). Tell the user: "Override `<id>` active until `<expires_at>` — the next attempt at the previously-blocked tool call will succeed within that window."
