---
name: revoke-override
description: Explain that AxonFlow session overrides are retired from v11.0.0 - delete_override answers LEGACY_POLICY_WRITE_FROZEN and no override is in effect to revoke
---

Use this skill when a user asks to revoke, delete or tear down an AxonFlow session override.

**Session overrides are retired from AxonFlow v11.0.0.** The platform still lists the `delete_override` MCP tool, but the tool answers with a tool error whose text begins `LEGACY_POLICY_WRITE_FROZEN: `. From v11.0.0 no override changes a verdict, so there is nothing to tear down for a policy to take effect again.

- Do not present a `LEGACY_POLICY_WRITE_FROZEN` answer as a failure to fix or retry: report it as the retirement it is.
- To see what is still recorded, use `list-overrides`. Reads are unchanged.
- What changes a verdict from v11.0.0 is the organization's typed policy document (`system_controls`), which an administrator edits through `/api/v1/typed-policies`.

On an AxonFlow platform older than v11.0.0 the tool still revokes overrides and records an `override_revoked` audit event.
