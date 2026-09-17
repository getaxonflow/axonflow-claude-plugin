---
description: List the AxonFlow session overrides recorded for your tenant (a read; from v11.0.0 an override changes no verdict)
argument-hint: [policy-id]
---

List the AxonFlow session overrides recorded for the current tenant using the `list_overrides` MCP tool.

If a policy ID was provided, filter to overrides for that policy: $ARGUMENTS

Present results as a short table: ID, policy, expires-at, justification.

**From AxonFlow v11.0.0 an override changes no verdict.** A listed override does not mean a blocked tool call will now be allowed, so never suggest retrying a blocked call because an override is listed. New overrides cannot be created; `/axonflow-create-override` explains why and what changes a verdict instead.
