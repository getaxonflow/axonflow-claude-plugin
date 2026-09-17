---
description: Fetch the full reasoning behind an AxonFlow policy decision (matched policies and recent hit count)
argument-hint: <decision-id>
---

Fetch the explanation for a previously-made AxonFlow policy decision using the `explain_decision` MCP tool.

Decision ID to explain: $ARGUMENTS

If no decision ID was provided, ask the user for one (it's typically returned in the original deny block reason or in `check_policy` responses).

Present the result clearly:

- Which policy fired, and its risk level when the platform reports one (`risk_level` and `allow_override` are null from AxonFlow v11.0.0)
- The decision reason
- The rolling 24h hit count for context

Do not suggest a session override: from AxonFlow v11.0.0 an override changes no verdict. If the user wants the verdict changed, explain that an administrator changes the policy in the organization's typed policy document (`/axonflow-create-override` has the details).
