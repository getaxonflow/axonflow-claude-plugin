---
description: Search AxonFlow's audit trail for recent tool executions and policy decisions
argument-hint: [time-window]
---

Search the AxonFlow audit trail using the `search_audit_events` MCP tool.

If the user provided a time-window argument (e.g. "last 6 hours" or "since yesterday at 3pm"), translate it to ISO 8601 and pass it as the `from` argument to `search_audit_events`. If they did not provide one, default to the last 15 minutes.

Argument: $ARGUMENTS

Then summarize the results as a short table: timestamp, tool name, decision, key details. Highlight any blocks or PII detections.
