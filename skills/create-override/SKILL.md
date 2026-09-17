---
name: create-override
description: Explain that AxonFlow session overrides are retired from v11.0.0 - create_override answers LEGACY_POLICY_WRITE_FROZEN and no override changes a verdict
---

Use this skill when a user has been blocked by an AxonFlow policy and asks to override it, bypass it, or create a session override.

**Session overrides are retired from AxonFlow v11.0.0.** The platform still lists the `create_override` MCP tool, but the tool no longer creates an override: it answers with a tool error whose text begins `LEGACY_POLICY_WRITE_FROZEN: `. On a session the platform cannot attribute to an individual user, it refuses for that reason first. Either way, no override would change a verdict.

Do not call `create_override` to unblock a tool call, and never tell the user that a retry will succeed. Instead:

1. Explain the block: use `explain-decision` with the `decision_id` from the block to show which policy fired and why.
2. Tell the user what changes a verdict from v11.0.0: an administrator enables, disables or re-actions the policy in the organization's typed policy document (a shipped system control is in its `system_controls` section), through the typed authoring route `/api/v1/typed-policies`.
3. If the user asks you to call the tool anyway, you may. Report its answer verbatim: it states the retirement.

On an AxonFlow platform older than v11.0.0 the tool still creates time-bounded session overrides; the platform's answer tells you which one you are talking to.
