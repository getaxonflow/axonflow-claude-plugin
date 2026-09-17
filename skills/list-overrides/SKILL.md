---
name: list-overrides
description: List the session overrides recorded for the caller's tenant - a read, unchanged on AxonFlow v11.0.0, where an override no longer changes a verdict
---

Use this skill to inventory the session overrides recorded for the caller's tenant, for example to audit what was created before an upgrade to AxonFlow v11.0.0.

Call the `list_overrides` MCP tool. Optional filters:

- `policy_id` - restrict to overrides for a specific policy
- `include_revoked` - include already-revoked overrides (default: false)

The response is `{ overrides: [...], count: <int> }` where each override carries `id`, `policy_id`, `expires_at`, `created_at`, and the original justification.

Present results as a short table: ID, policy, expires-at, justification.

**From AxonFlow v11.0.0 an override changes no verdict.** A listed override does not mean a blocked tool call will now be allowed, so never suggest retrying a blocked call because an override is listed. New overrides cannot be created; `create-override` explains why and what changes a verdict instead.
