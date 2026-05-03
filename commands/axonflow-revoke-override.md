---
description: Revoke an active AxonFlow session override (emits an audit event)
argument-hint: <override-id>
---

Revoke an active AxonFlow session override using the `delete_override` MCP tool.

Override ID to revoke: $ARGUMENTS

If no override ID was provided, suggest the user run `/axonflow-list-overrides` first to find the override they want to revoke.

After revocation:

- The next policy evaluation will not consult the revoked override
- The platform records an `override_revoked` audit event for compliance
- A 404 from the platform means the override was already revoked or never existed; surface this as "override not found or already revoked" rather than a hard error

Confirm to the user: "Override `<id>` revoked. The previously-blocked tool will now require a fresh override or a policy change before it succeeds."
