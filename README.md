# AxonFlow Plugin for Claude Code

Policy enforcement, PII detection, and audit trails for Claude Code.

This plugin automatically governs tool calls — checking policies before execution, scanning outputs for PII/secrets after execution, and recording audit entries for compliance. No manual intervention needed.

**Governed tools:** `Bash`, `Write`, `Edit`, `NotebookEdit`, and all MCP server tools (`mcp__*`). Read-only tools (`Read`, `Glob`, `Grep`) are not governed by default since they don't modify state or send data externally.

## How It Works

```
Claude selects a tool (Bash, Write, MCP, etc.)
    │
    ▼
PreToolUse hook fires automatically
    │ → check_policy("claude_code.Bash", "rm -rf /")
    │
    ├─ BLOCKED → Claude receives denial reason, tool never runs
    │
    └─ ALLOWED → Tool executes normally
                      │
                      ▼
                 PostToolUse hook fires automatically
                      │ → audit_tool_call(tool, input, output)  [background]
                      │ → check_output(tool result for PII/secrets)
                      │
                      ├─ PII found → Claude instructed to use redacted version
                      │              (original output is not transformed — Claude
                      │               receives guidance to not expose raw PII)
                      └─ Clean → Silent, no interruption
```

## Prerequisites

AxonFlow must be running. No LLM provider keys needed — Claude Code handles LLM calls, AxonFlow only enforces policies and records audit trails.

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

## What Happens Automatically

| Event | Hook | Action |
|-------|------|--------|
| Before every tool call | PreToolUse | `check_policy` evaluates tool inputs against governance policies |
| After every tool call | PostToolUse | `audit_tool_call` records execution in compliance audit trail |
| After every tool call | PostToolUse | `check_output` scans output for PII/secrets, instructs Claude to use redacted version |

Governed tools: `Bash`, `Write`, `Edit`, `NotebookEdit`, and all MCP tools (`mcp__*`).

**Fail behavior:**
- AxonFlow unreachable (network failure) → fail-open, tool execution continues
- AxonFlow auth/config error → fail-closed, tool call denied until configuration is fixed
- PostToolUse failures → never block (audit and PII scan are best-effort)

## MCP Tools (Also Available for Explicit Use)

In addition to automatic hooks, Claude can call these tools explicitly:

| Tool | Purpose |
|------|---------|
| `check_policy` | Evaluate specific inputs against policies |
| `check_output` | Scan specific content for PII/secrets |
| `audit_tool_call` | Record additional audit entries |
| `list_policies` | List active governance policies (static + dynamic) |
| `get_policy_stats` | Get governance activity summary |

## What Gets Checked

AxonFlow's system policies cover:

- **Dangerous commands**: reverse shells, `rm -rf`, `curl | bash`, credential access
- **PII detection**: SSN, credit card, email, phone, Aadhaar, PAN — with redaction
- **SQL injection**: 37+ detection patterns
- **Secrets exposure**: API keys, connection strings, code secrets
- **SSRF**: cloud metadata endpoint and internal network blocking
- **Path traversal**: workspace escape pattern detection

## Plugin Structure

```
axonflow-claude-plugin/
├── .claude-plugin/
│   └── plugin.json        # Plugin metadata
├── .mcp.json               # MCP server connection (5 governance tools)
├── hooks/
│   └── hooks.json          # PreToolUse + PostToolUse hook definitions
├── scripts/
│   ├── pre-tool-check.sh   # Policy evaluation before tool execution
│   └── post-tool-audit.sh  # Audit logging + PII scan after execution
└── README.md
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
