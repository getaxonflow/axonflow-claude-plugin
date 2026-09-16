---
description: Explain that AxonFlow session overrides are retired from v11.0.0 (create_override answers LEGACY_POLICY_WRITE_FROZEN) and what changes a verdict instead
argument-hint: <policy-id> <static|dynamic> <reason>
---

The user asked to create a session override against an AxonFlow policy.

Arguments: $ARGUMENTS

**Session overrides are retired from AxonFlow v11.0.0.** The platform still lists the `create_override` MCP tool, but it no longer creates an override: it answers with a tool error whose text begins `LEGACY_POLICY_WRITE_FROZEN: `. On a session the platform cannot attribute to an individual user, it refuses for that reason first. Either way, no override changes a verdict.

Do not tell the user that the blocked tool call will succeed on a retry. Instead:

1. If the user has the `decision_id` from the block, use `/axonflow-explain-decision` to show which policy fired and why.
2. Tell the user what changes a verdict from v11.0.0: an administrator enables, disables or re-actions the policy in the organization's typed policy document (a shipped system control is in its `system_controls` section), through the typed authoring route `/api/v1/typed-policies`.
3. If the user asks you to call `create_override` anyway, you may. Report its answer verbatim: it states the retirement.

On an AxonFlow platform older than v11.0.0 the tool still creates time-bounded session overrides; the platform's answer tells you which one you are talking to.
