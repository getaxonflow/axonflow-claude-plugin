# AxonFlow Plugin for Claude Code

Policy enforcement, PII detection, and audit trails for Claude Code.

## Prerequisites

AxonFlow must be running. No LLM provider keys needed — Claude Code handles LLM calls, AxonFlow only enforces policies and records audit trails.

```bash
git clone https://github.com/getaxonflow/axonflow.git
cd axonflow && docker compose up -d
```

Verify: `curl -s http://localhost:8080/health | jq .`

## Install

```bash
claude /plugin install axonflow@claude-plugins-official
```

Or load locally for testing:

```bash
claude --plugin-dir /path/to/this/directory
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
| `check_policy` | Evaluate tool inputs against governance policies before execution |
| `check_output` | Scan tool output for PII, secrets, and policy violations |
| `audit_tool_call` | Record tool execution in the compliance audit trail |
| `list_policies` | List active governance policies (names, categories, patterns) |
| `get_policy_stats` | Get governance activity summary (checks, blocks, top policies) |

## What Gets Governed

AxonFlow's 83 built-in system policies protect against:

- **PII leakage**: SSN, credit card, email, phone, Aadhaar, PAN detection and redaction
- **SQL injection**: 37+ detection patterns
- **Dangerous commands**: reverse shells, destructive operations, credential access
- **Secrets exposure**: API keys, connection strings, code secrets
- **SSRF**: cloud metadata endpoint and internal network blocking
- **Path traversal**: workspace escape pattern detection

## How It Works

```
Claude Code selects a tool (Bash, Write, MCP, etc.)
    │
    ▼
check_policy("claude_code.Bash", "rm -rf /tmp/*")
    │
    ├─ BLOCKED → Claude receives block reason, skips execution
    │
    └─ ALLOWED → Tool executes normally
                      │
                      ▼
                 check_output(tool result)
                      │
                      ├─ PII found → Redacted data returned
                      └─ Clean → Original data returned
                                    │
                                    ▼
                               audit_tool_call(tool, input, output)
                                    │
                                    └─ Audit entry created
```

## Links

- [AxonFlow Documentation](https://docs.getaxonflow.com)
- [Claude Code Integration Guide](https://docs.getaxonflow.com/docs/integration/claude-code/)
- [Policy Enforcement](https://docs.getaxonflow.com/docs/mcp/policy-enforcement/)
- [Self-Hosted Deployment](https://docs.getaxonflow.com/docs/deployment/self-hosted/)
- [Security Best Practices](https://docs.getaxonflow.com/docs/security/best-practices/)
- [Source Code](https://github.com/getaxonflow/axonflow)

## License

MIT
