---
name: audit-search
description: Search the AxonFlow audit trail for recent tool executions, policy decisions, and PII detections — use to answer "what happened recently?" or to gather compliance evidence
---

Use this skill when a user asks about recent activity, which tools got blocked, or wants compliance evidence for a window of time.

Call the `search_audit_events` MCP tool. Optional arguments:

- `from` — ISO 8601 start time (defaults to last 15 minutes)
- `to` — ISO 8601 end time (defaults to now)
- `limit` — max events (default 20, max 100)
- `request_type` — filter by type (e.g. `tool_call_audit`, `llm_call`)

Present results as a short table: timestamp, tool name, decision (allowed/blocked), and key details (block reason or matched policy if any).
