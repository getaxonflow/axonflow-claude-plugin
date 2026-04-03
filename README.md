# AxonFlow Plugin for Claude Code

Governance tools for Claude Code — policy checking, PII scanning, and audit trails via MCP.

This plugin gives Claude access to five AxonFlow governance tools. Claude can use them to check policies before running commands, scan outputs for sensitive data, and log actions for compliance. **These are tools Claude can call, not automatic hooks** — automatic pre/post-tool enforcement is planned for a future release.

## Prerequisites

AxonFlow must be running. No LLM provider keys needed — Claude Code handles LLM calls, AxonFlow only evaluates policies and records audit trails.

```bash
git clone https://github.com/getaxonflow/axonflow.git
cd axonflow && docker compose up -d
```

Verify: `curl -s http://localhost:8080/health | jq .`

## Install

Load locally for testing:

```bash
claude --plugin-dir /path/to/this/directory
```

Or once listed in the official marketplace:

```bash
/plugin install axonflow@claude-plugins-official
```

## Configure

Set environment variables for authentication:

```bash
# Community mode (local development) — any values work
export AXONFLOW_AUTH=$(echo -n "demo:demo-secret" | base64)

# Enterprise mode — use your AxonFlow client credentials
export AXONFLOW_AUTH=$(echo -n "your-client-id:your-client-secret" | base64)

# Custom endpoint (default: http://localhost:8080)
export AXONFLOW_ENDPOINT=http://your-axonflow-host:8080
```

## Tools

Once installed, Claude Code has access to five governance tools:

| Tool | Purpose |
|------|---------|
| `check_policy` | Evaluate tool inputs against governance policies |
| `check_output` | Scan tool output for PII, secrets, and policy violations |
| `audit_tool_call` | Record tool execution in the compliance audit trail |
| `list_policies` | List active governance policies (static + dynamic) |
| `get_policy_stats` | Get governance activity summary (checks, blocks, top policies) |

Claude can call these tools proactively when it determines governance checks are appropriate. For example, before running a potentially dangerous shell command or after receiving output that might contain PII.

## What Gets Checked

AxonFlow's 83 built-in system policies cover:

- **PII detection**: SSN, credit card, email, phone, Aadhaar, PAN — with redaction
- **SQL injection**: 37+ detection patterns
- **Dangerous commands**: reverse shells, destructive operations, credential access
- **Secrets exposure**: API keys, connection strings, code secrets
- **SSRF**: cloud metadata endpoint and internal network blocking
- **Path traversal**: workspace escape pattern detection

## Example Usage

```
You: "Delete all temp files from the server"

Claude calls check_policy("claude_code.Bash", "rm -rf /tmp/*")
  → AxonFlow: allowed=true (safe path, not root)

Claude runs: rm -rf /tmp/*

Claude calls audit_tool_call("Bash", input={command: "rm -rf /tmp/*"}, success=true)
  → Audit entry recorded
```

```
You: "Show me the customer database query results"

Claude runs a query, gets results containing SSN 123-45-6789

Claude calls check_output("claude_code.mcp__postgres", message="SSN: 123-45-6789")
  → AxonFlow: PII detected, redacted_message="SSN: [REDACTED:ssn]"

Claude shows redacted output to user
```

## Future: Automatic Enforcement

Phase 2 of this plugin will add PreToolUse and PostToolUse hooks that automatically call `check_policy` and `check_output` around every tool execution — no manual calls needed. This is tracked in [axonflow-enterprise#1484](https://github.com/getaxonflow/axonflow-enterprise/issues/1484).

## Links

- [AxonFlow Documentation](https://docs.getaxonflow.com)
- [Claude Code Integration Guide](https://docs.getaxonflow.com/docs/integration/claude-code/)
- [Policy Enforcement](https://docs.getaxonflow.com/docs/mcp/policy-enforcement/)
- [Self-Hosted Deployment](https://docs.getaxonflow.com/docs/deployment/self-hosted/)
- [Security Best Practices](https://docs.getaxonflow.com/docs/security/best-practices/)
- [Source Code](https://github.com/getaxonflow/axonflow)

## License

MIT
