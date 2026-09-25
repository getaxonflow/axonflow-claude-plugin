---
name: explain-decision
description: Fetch the full reasoning behind an AxonFlow policy decision - matched policies and recent hit count
---

Use this skill when a user asks "why was that blocked?", "what policy fired?", or wants the context behind an allow or deny before deciding what to do next.

Call the `explain_decision` MCP tool with the `decision_id` returned in the original policy-check response (e.g. `decision_id` on a `check_policy` response or in the deny block reason).

The response includes:

- `policy_matches[]` - every matched policy with `policy_id` and `policy_name` (their `risk_level` and `allow_override` are null from AxonFlow v11.0.0)
- `decision` - `"allow"` or `"deny"`
- `reason` - human-readable summary
- `risk_level` - `critical`, `high`, `medium` or `low` on platforms before v11.0.0; null from v11.0.0
- `override_available` - always `false` from AxonFlow v11.0.0, where session overrides are retired
- `historical_hit_count_session` - how often this exact decision_id pattern has fired in the rolling 24h window

Present the result as a short summary: which policy fired, and its risk level when the platform reports one. Do not suggest a session override: from v11.0.0 an override changes no verdict. If the user wants the verdict changed, explain that an administrator changes the policy in the organization's typed policy document (`create-override` has the details).
