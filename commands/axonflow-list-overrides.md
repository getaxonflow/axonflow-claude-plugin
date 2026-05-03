---
description: List active AxonFlow session overrides scoped to your tenant
argument-hint: [policy-id]
---

List active AxonFlow session overrides using the `list_overrides` MCP tool.

If a policy ID was provided, filter to overrides for that policy: $ARGUMENTS

Otherwise list all active overrides for the current tenant.

Present results as a short table: ID, policy, expires-at, justification. Flag any override expiring more than 12 hours from now as "long-lived — consider revoking when the work that needed it is done".
