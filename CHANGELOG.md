# Changelog

## [Unreleased]

### Fixed

- **MCP tools not discoverable in Claude Code.** Claude Code's HTTP MCP client ignores static `headers` in `.mcp.json` and always attempts OAuth discovery first. Switched to `headersHelper` which generates auth headers via a shell command, bypassing the OAuth flow. Community mode (no auth) returns empty headers.

### Added

- `scripts/mcp-auth-headers.sh` — auth header generator for MCP server connection. Supports community mode (no auth) and enterprise mode (Basic auth via `AXONFLOW_AUTH`).
- `tests/E2E_TESTING_PLAYBOOK.md` — comprehensive testing playbook covering hooks, MCP tools, integration activation, and edge cases.

---

## [0.1.0] - 2026-04-04

### Added

- MCP server integration with 6 governance tools: `check_policy`, `check_output`, `audit_tool_call`, `list_policies`, `get_policy_stats`, `search_audit_events`
- Automatic PreToolUse hook: evaluates tool inputs against AxonFlow policies before execution. Blocks dangerous commands, reverse shells, SSRF, credential access, path traversal.
- Automatic PostToolUse hook: records tool execution in AxonFlow audit trail and scans output for PII/secrets.
- Audit logging for blocked attempts: denied tool calls are recorded in the audit trail for compliance evidence.
- Fail-open on network failure, fail-closed on auth/config errors.
- Governed tools: `Bash`, `Write`, `Edit`, `NotebookEdit`, and all MCP tools (`mcp__*`).
- 21 regression tests with mock MCP server (`tests/test-hooks.sh`).
- CI workflow: shell syntax check, regression tests, plugin structure validation.

### Configuration

- `AXONFLOW_ENDPOINT` — AxonFlow Agent URL (default: `http://localhost:8080`)
- `AXONFLOW_AUTH` — Base64-encoded `clientId:clientSecret` for Basic auth
- No LLM provider keys required — Claude Code handles LLM calls, AxonFlow only enforces policies.

### Architecture

Matches the OpenClaw plugin pattern:

| OpenClaw Hook | Claude Code Hook | Behavior |
|---|---|---|
| `before_tool_call` | PreToolUse | Policy check before execution |
| `after_tool_call` | PostToolUse | Audit trail recording |
| `message_sending` | PostToolUse | PII/secret scanning on output |
