---
description: List recent AxonFlow governance decisions for the current user/tenant — surface "what just got blocked", trace decision history, or drive an appeal flow
argument-hint: [optional decision filter: allow|deny|require_approval]
---

List recent governance decisions made by AxonFlow for the current user/tenant using the `list_recent_decisions` MCP tool.

Optional decision filter (allow|deny|require_approval): $ARGUMENTS

If the user provided a filter, pass it as the `decision` argument; otherwise call without filters and let the platform return everything within the tier window.

Useful when the user asks:
- "what just got blocked?"
- "show me my recent denials"
- "what happened in the last hour?"
- "did anything need approval today?"

Tier-throttled per the platform's Free/Pro window+limit:
- SaaS Free / self-hosted Community: last 24h, max 5 rows per page
- SaaS Pro: last 30 days, max 100 rows per page
- Self-hosted Evaluation: last 14 days, max 100 rows per page
- Self-hosted Enterprise: full retention, max 1000 rows per page

Free callers exceeding the page cap will get the V1 upgrade envelope instead of decisions — render that to the user verbatim (it includes the upgrade URL and locked wording). Don't swallow it.

Present each row as a concise one-liner: `<timestamp> <decision> <policy_id> on <tool_signature>`.
