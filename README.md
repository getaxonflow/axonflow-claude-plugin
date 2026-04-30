# AxonFlow Plugin for Claude Code

**Runtime governance for Claude Code: block dangerous commands before they run, scan every tool output for PII and secrets, and keep a compliance-grade audit trail — without leaving your terminal.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-7c3aed)](https://docs.claude.com/claude-code/plugins)

> **→ Full integration walkthrough:** **[docs.getaxonflow.com/docs/integration/claude-code](https://docs.getaxonflow.com/docs/integration/claude-code/)** — architecture, policy examples, latency numbers, troubleshooting, and the 10 MCP tools the platform exposes.

> **Upgrade strongly recommended.** AxonFlow ships substantial monthly security and quality hardening; staying on the latest major is the security-supported release line. [Latest release](https://github.com/getaxonflow/axonflow-claude-plugin/releases/latest) · [Security advisories](https://github.com/getaxonflow/axonflow-claude-plugin/security/advisories)

---

## Why you'd add this

Claude Code is Anthropic's official CLI — a fast, agentic coding assistant that edits files, runs shell commands, and calls MCP servers. It's excellent at developer productivity. It was never designed to be the layer where your security and compliance team lives.

The gaps start surfacing the moment Claude Code moves from one developer's laptop to a team or production setting:

| Production requirement | Claude Code alone | With this plugin |
|---|---|---|
| Policy enforcement before tool execution | Hooks available, no governance logic | **80+ built-in policies evaluated on every governed tool call** |
| Dangerous command blocking (`rm -rf /`, reverse shells, `curl \| bash`) | Not addressed | **Blocked before execution with decision context** |
| PII / secrets detection in tool outputs | Developer responsibility | **Auto-scan; Claude is instructed to use redacted version** |
| SQL-injection detection on MCP queries | MCP server's problem | **30+ patterns evaluated on every MCP tool call** |
| Compliance-grade audit trail | Session logs, not compliance-formatted | **Every governed call recorded with policies, decision, duration** |
| Decision explainability after a block | Generic hook failure message | **`decision_id` surfaced in deny reason; `explain_decision` MCP tool returns the full record** |
| Self-service, time-bounded exceptions | Not available | **`create_override` with mandatory justification, fully audited** |
| Cloud metadata / SSRF / path traversal blocking | Not addressed | **Built in** |

You get all of that with zero change to how developers use Claude Code. Hooks fire automatically, the deny message tells you why, MCP tools are there when you want to investigate or unblock yourself.

---

## How it works

```
Claude selects a tool (Bash, Write, Edit, NotebookEdit, mcp__*)
    │
    ▼
PreToolUse hook fires automatically
    │ → check_policy("claude_code.Bash", "rm -rf /")
    │
    ├─ BLOCKED → Claude receives denial reason with decision_id + risk_level,
    │            can call explain_decision / create_override to unblock
    │
    └─ ALLOWED → Tool executes normally
                      │
                      ▼
                 PostToolUse hook fires automatically
                      │ → audit_tool_call(tool, input, output)  [non-blocking]
                      │ → check_output(tool result for PII/secrets)
                      │
                      ├─ Sensitive data found → Claude instructed to use
                      │                          redacted version in its reply
                      └─ Clean → Silent
```

**Governed tools:** `Bash`, `Write`, `Edit`, `NotebookEdit`, and all MCP server tools (`mcp__*`). Read-only tools (`Read`, `Glob`, `Grep`) are not governed by default — they don't modify state or send data externally.

**Fail behavior:**
- AxonFlow unreachable (network) → fail-open, tool execution continues
- AxonFlow auth/config error → fail-closed, tool call denied until config is fixed
- PostToolUse failures → never block (audit and PII scan are best-effort)

---

## Where this kicks in during real coding

### 1. The MCP data-exposure problem

A developer connects an MCP server to a production database for debugging. Claude Code queries customer records. Results flow through the conversation with PII intact. Session logs exist but they aren't structured for compliance queries.

**With the plugin:** `check_policy` fires before the MCP query runs (SQL injection scan, policy scan), `check_output` scans the result for SSN / credit card / email / phone / API keys, and `audit_tool_call` records the full interaction with matched policies and decision ID.

### 2. The accidental production change

A developer types *"fix the database issue."* Claude Code picks a `Bash` tool and runs a migration against prod. The command ran because nothing stopped it.

**With the plugin:** a dynamic policy scoped to production patterns matches, the call is denied with a decision ID, and Claude surfaces the deny reason in the REPL. A developer can call `explain_decision` to see exactly which policy family triggered, then `create_override` with justification if they have the authority — all without leaving the session.

### 3. The security-review block

A team wants to deploy Claude Code at scale and security says no: *"No policy enforcement on MCP queries, PII flows through conversations unchecked, bash commands aren't governed, audit trail isn't compliance-ready, no approval gates."*

**With the plugin:** every one of those gaps is filled at the plugin layer. The productivity surface doesn't change.

---

## Try AxonFlow on a real plugin rollout

We're opening limited **Plugin Design Partner** slots.

30-minute hook lifecycle review, policy pack scoping, override workflow design, and IDE/CLI rollout pattern walkthrough — for solo developers and small teams putting governance on Claude Code.

[Apply here](https://getaxonflow.com/plugins/design-partner?utm_source=readme_plugin_claude) or email [design-partners@getaxonflow.com](mailto:design-partners@getaxonflow.com). Personal email is fine — solo developers welcome.

### See AxonFlow in Action

Three short videos covering different angles of the platform:

- **[Community Quickstart Demo (Code + Terminal, 2.5 min)](https://youtu.be/BSqU1z0xxCo)** — governed calls, PII block, Gateway Mode with LangChain/CrewAI, and MAP from YAML
- **[Runtime Control Demo (Portal + Workflow, 3 min)](https://youtu.be/6UatGpn7KwE)** — approvals, retry safety, execution state, and the audit viewer
- **[Architecture Deep Dive (12 min)](https://youtu.be/Q2CZ1qnquhg)** — how the control plane works, policy enforcement flow, and multi-agent planning

### Plugin Evaluation Tier (Free 90-day License)

Outgrown Community on a real plugin install? Evaluation unlocks the capacity and features that matter for plugin users — without moving to Enterprise yet:

| Capability | Community | Evaluation (Free) | Enterprise |
|---|---|---|---|
| Tenant policies | 20 | 50 | Unlimited |
| Org-wide policies | 0 | 5 | Unlimited |
| Audit retention | 3 days | 14 days | Up to 10 years |
| HITL approval gates | — | 25 pending, 24h expiry | Unlimited, 24h |
| Evidence export (CSV/JSON) | — | 5,000 records · 14d window · 3/day | Unlimited |
| Policy simulation | — | 300/day | Unlimited |
| Session overrides (self-service unblock) | — | — | Enterprise-only |

Org-wide policies and session overrides are **Enterprise-only** — those are the actual upgrade triggers for plugin users.

[Get a free Plugin Evaluation license](https://getaxonflow.com/plugins/evaluation-license?utm_source=readme_plugin_claude_eval)

---

## Install

### Add this repo as a custom marketplace (recommended)

```
/plugin marketplace add getaxonflow/axonflow-claude-plugin
/plugin install axonflow
```

### Or load locally for testing

```bash
git clone https://github.com/getaxonflow/axonflow-claude-plugin.git
claude --plugin-dir /path/to/axonflow-claude-plugin
```

> The plugin has been submitted to the official Anthropic marketplace (`anthropics/claude-plugins-official`) and is currently in Anthropic's review queue. Until it appears in `/plugin > Discover`, use one of the install methods above.

---

## Where your data goes

The plugin governs tool calls and outbound messages by sending each one to an AxonFlow endpoint for policy evaluation and audit. The endpoint is selected by which of `AXONFLOW_ENDPOINT` / `AXONFLOW_AUTH` you have set when the hooks fire.

### Default: AxonFlow Community SaaS

If you do not set `AXONFLOW_ENDPOINT` or `AXONFLOW_AUTH`, the plugin connects to **AxonFlow Community SaaS** at `https://try.getaxonflow.com` and registers a tenant on first run. No setup, no Docker, no infrastructure — install the plugin and use Claude Code. Every hook invocation logs a one-line canary on stderr so you always know which mode is active:

```
[AxonFlow] Connected to AxonFlow at https://try.getaxonflow.com (mode=community-saas)
```

| What goes to `try.getaxonflow.com` | What does NOT |
|---|---|
| Tool name + arguments before each governed call | LLM provider API keys |
| Outbound message bodies before delivery (PII/secret scan) | Claude Code conversation history outside governed tools |
| Anonymous 7-day heartbeat (plugin version, OS, runtime) | Files outside the Claude Code runtime |

Community SaaS is intended for evaluation and prototyping. Best-effort retention up to 1 year; tenants idle for 3 months are terminated. We don't offer reliability or security guarantees on the shared endpoint. Read the [Try AxonFlow — Free Trial Server](https://docs.getaxonflow.com/docs/deployment/community-saas/) page for the full disclosure, including data retention and registration mechanics.

### Self-hosted: your own AxonFlow

For real workflows, real systems, or sensitive data, run AxonFlow on your own infrastructure. Everything stays local; nothing leaves your network except the anonymous 7-day heartbeat.

```bash
git clone https://github.com/getaxonflow/axonflow.git
cd axonflow && docker compose up -d

# verify
curl -s http://localhost:8080/health | jq .

# point the plugin at your local agent
export AXONFLOW_ENDPOINT=http://localhost:8080
```

See the [Self-Hosted Deployment Guide](https://docs.getaxonflow.com/docs/deployment/self-hosted/) for prerequisites and production options. For production-scale workloads, [request an evaluation license](https://getaxonflow.com/plugins/evaluation-license?utm_source=readme_plugin_claude_eval). For compliance-grade SLA + enterprise features, [contact us](https://getaxonflow.com/enterprise).

### Air-gapped: zero outbound

For environments where no outbound traffic is permitted at all, set both:

```bash
export AXONFLOW_COMMUNITY_SAAS=0   # disable Community SaaS auto-bootstrap
export AXONFLOW_TELEMETRY=off      # disable the anonymous 7-day heartbeat
export AXONFLOW_ENDPOINT=http://your-internal-axonflow:8080
```

With both env vars set and `AXONFLOW_ENDPOINT` pointing at a same-network instance, no traffic leaves your environment.

---

## Configure

The plugin emits a one-line canary on every hook invocation so you always know which AxonFlow you're connected to:

```
[AxonFlow] Connected to AxonFlow at https://try.getaxonflow.com (mode=community-saas)
```

To change connection target:

```bash
# Self-hosted local agent
export AXONFLOW_ENDPOINT=http://localhost:8080

# Self-hosted remote agent with credentials
export AXONFLOW_ENDPOINT=https://axonflow.your-company.com
export AXONFLOW_AUTH=$(echo -n "your-client-id:your-client-secret" | base64)

# Default (Community SaaS) — leave both unset
unset AXONFLOW_ENDPOINT AXONFLOW_AUTH

# Optional: increase hook timeout for remote / VPN'd deployments
# (PreToolUse default 8s, PostToolUse default 5s)
export AXONFLOW_TIMEOUT_SECONDS=12
```

When `AXONFLOW_AUTH` is unset and `AXONFLOW_ENDPOINT` is unset, the plugin defaults to AxonFlow Community SaaS — no further configuration needed.

---

## What gets checked

AxonFlow ships with **80+ built-in system policies** that apply to Claude Code automatically. No configuration required — new policies added to the platform are immediately enforced in every session.

| Category | Coverage |
|---|---|
| **Dangerous commands** | Reverse shells (`nc -e`, `bash -i`, `/dev/tcp/`), `rm -rf /`, `dd if=`, `curl \| bash`, credential file access (`cat ~/.ssh/`, `cat ~/.aws/`), path traversal |
| **SQL injection** | 30+ patterns including UNION injection, stacked queries, auth bypass, encoding tricks |
| **PII detection** | SSN, credit card, Aadhaar, PAN, email, phone, NRIC/FIN (Singapore), and more — with redaction |
| **Secrets exposure** | API keys, connection strings, hardcoded credentials, code secrets |
| **SSRF** | Cloud metadata endpoint (`169.254.169.254`) and internal-network blocking |
| **Prompt injection** | Instruction override, jailbreak attempts, role hijacking |
| **Claude Code-specific** | `.claude/settings.json` write protection, `.claude/hooks/*.json` modification warnings (enabled via `AXONFLOW_INTEGRATIONS=claude-code`) |

Custom policies are easy — `POST /api/v1/dynamic-policies` or the Customer Portal. See [Policy Enforcement](https://docs.getaxonflow.com/docs/mcp/policy-enforcement/).

---

## The 10 MCP tools Claude can call

In addition to automatic hooks, the agent's MCP server exposes **10 tools** Claude can call directly. All served by the platform at `/api/v1/mcp-server` — the plugin's `.mcp.json` just points Claude there. New platform tools are immediately available.

### Governance (6)

| Tool | Purpose |
|------|---------|
| `check_policy` | Evaluate specific inputs against policies |
| `check_output` | Scan specific content for PII/secrets |
| `audit_tool_call` | Record an additional audit entry |
| `list_policies` | List active governance policies (system + tenant) |
| `get_policy_stats` | Summary of governance activity |
| `search_audit_events` | Search individual audit records for debugging and compliance evidence |

### Decision explainability & session overrides (4)

| Tool | Purpose |
|------|---------|
| `explain_decision` | Return the full [DecisionExplanation](https://docs.getaxonflow.com/docs/governance/explainability/) for a decision ID |
| `create_override` | Create a time-bounded, audit-logged session override (mandatory justification) |
| `delete_override` | Revoke an active session override |
| `list_overrides` | List active overrides scoped to the caller's tenant |

**The inline-unblock workflow:** a policy block → the deny reason includes `decision_id` and `risk_level` → the developer asks Claude to call `explain_decision` → if the decision is overridable, `create_override` unblocks with justification. No separate admin surface, full audit trail.

See [Session Overrides](https://docs.getaxonflow.com/docs/governance/overrides/).

---

## Latency

| Operation | Typical overhead |
|-----------|-----------------|
| Policy pre-check | 2–5 ms |
| PII detection | 1–3 ms |
| SQL-injection scan | 1–2 ms |
| Audit write (async) | 0 ms (non-blocking) |
| **Total per-tool overhead** | **3–10 ms** |

Imperceptible in interactive Claude Code sessions.

---

## Sister integrations

Same governance platform, same 80+ policies, same 10 MCP tools — different agent hosts:

| Integration | Repo | Docs |
|---|---|---|
| Claude Code | *this repo* | [claude-code](https://docs.getaxonflow.com/docs/integration/claude-code/) |
| Anthropic Computer Use | Docs-only integration (uses the Agent SDK pattern) | [computer-use](https://docs.getaxonflow.com/docs/integration/computer-use/) |
| Claude Agent SDK | Docs-only integration | [claude-agent-sdk](https://docs.getaxonflow.com/docs/integration/claude-agent-sdk/) |
| Cursor IDE | [axonflow-cursor-plugin](https://github.com/getaxonflow/axonflow-cursor-plugin) | [cursor](https://docs.getaxonflow.com/docs/integration/cursor/) |
| OpenAI Codex | [axonflow-codex-plugin](https://github.com/getaxonflow/axonflow-codex-plugin) | [codex](https://docs.getaxonflow.com/docs/integration/codex/) |
| OpenClaw | [axonflow-openclaw-plugin](https://github.com/getaxonflow/axonflow-openclaw-plugin) | [openclaw](https://docs.getaxonflow.com/docs/integration/openclaw/) |

---

## Plugin structure

```
axonflow-claude-plugin/
├── .claude-plugin/
│   ├── plugin.json        # Plugin metadata
│   └── marketplace.json   # Marketplace listing
├── .mcp.json              # MCP server connection (points at the platform)
├── hooks/
│   └── hooks.json         # PreToolUse + PostToolUse hook definitions
├── scripts/
│   ├── pre-tool-check.sh    # Policy evaluation before tool execution
│   ├── post-tool-audit.sh   # Audit + PII scan after execution
│   ├── mcp-auth-headers.sh  # Basic-auth header generation for MCP
│   └── telemetry-ping.sh    # Anonymous telemetry (fires once per install)
└── tests/
    ├── test-hooks.sh        # Hook regression (mock server)
    ├── E2E_TESTING_PLAYBOOK.md
    └── e2e/                 # Smoke E2E against live AxonFlow
```

---

## Testing

```bash
# Hook regression tests (no live stack required)
./tests/test-hooks.sh

# Smoke E2E against a live AxonFlow at localhost:8080
bash tests/e2e/smoke-block-context.sh
```

The smoke scenario installs the plugin's `pre-tool-check.sh` against a running platform, feeds a SQLi-bearing Bash tool invocation through it, and asserts the hook returns the `permissionDecision: deny` shape with the richer-context markers (`decision:`, `risk:`) in the reason text. Exits 0 with `SKIP:` if no stack is reachable. Run in CI via `workflow_dispatch` when a reachable endpoint is configured.

For the broader validation story — explain-decision, override lifecycle, audit-filter parity, cache invalidation — see the [Claude Code integration guide](https://docs.getaxonflow.com/docs/integration/claude-code/) and the [governance test scenarios](https://docs.getaxonflow.com/docs/testing/) documentation.

---

## Telemetry

Anonymous heartbeat at most once every 7 days per machine: plugin version, OS, architecture, bash version, AxonFlow platform version, deployment mode (community-saas / self-hosted production / self-hosted development). **Never** tool arguments, message contents, or policy data. The stamp file mtime advances only after the HTTP POST returns 2xx, so a transient network failure does not silence telemetry until the next window.

Opt out: set `AXONFLOW_TELEMETRY=off` in the environment Claude Code runs in.

`DO_NOT_TRACK` is **not** honored as an opt-out for AxonFlow telemetry. It is commonly inherited from host tools and developer environments — and in Claude Code specifically, the CLI injects `DO_NOT_TRACK=1` into every hook subprocess regardless of user intent. That makes it an unreliable expression of user intent, so AxonFlow telemetry is controlled exclusively by `AXONFLOW_TELEMETRY=off`.

Guarded by a stamp file at `$HOME/.cache/axonflow/claude-code-plugin-telemetry-sent` (delete to re-send). Details: [docs.getaxonflow.com/docs/telemetry](https://docs.getaxonflow.com/docs/telemetry/).

---

## Links

- **[Claude Code Integration Guide](https://docs.getaxonflow.com/docs/integration/claude-code/)** — the full walkthrough (recommended starting point)
- [AxonFlow Documentation](https://docs.getaxonflow.com)
- [Policy Enforcement](https://docs.getaxonflow.com/docs/mcp/policy-enforcement/)
- [Decision Explainability](https://docs.getaxonflow.com/docs/governance/explainability/)
- [Session Overrides](https://docs.getaxonflow.com/docs/governance/overrides/)
- [Self-Hosted Deployment](https://docs.getaxonflow.com/docs/deployment/self-hosted/)
- [Security Best Practices](https://docs.getaxonflow.com/docs/security/best-practices/)
- [Anthropic Computer Use Integration](https://docs.getaxonflow.com/docs/integration/computer-use/)
- [Claude Agent SDK Integration](https://docs.getaxonflow.com/docs/integration/claude-agent-sdk/)
- [AxonFlow source](https://github.com/getaxonflow/axonflow)

## License

MIT
