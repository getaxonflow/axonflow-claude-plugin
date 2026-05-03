---
description: Fetch the full reasoning behind an AxonFlow policy decision (matched policies, risk level, override availability)
argument-hint: <decision-id>
---

Fetch the explanation for a previously-made AxonFlow policy decision using the `explain_decision` MCP tool.

Decision ID to explain: $ARGUMENTS

If no decision ID was provided, ask the user for one (it's typically returned in the original deny block reason or in `check_policy` responses).

Present the result clearly:

- Which policy fired (name + risk level)
- The decision reason
- Whether an override is available; if yes, suggest the user invoke `/axonflow-create-override` with a justification
- The rolling 24h hit count for context
