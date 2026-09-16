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
| A governed call when AxonFlow cannot decide | Not addressed | **A rejected credential, a limit or a refusal blocks; an unreachable agent is never silent ([posture](#when-axonflow-cannot-decide))** |
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
    ├─ BLOCKED → Claude receives denial reason with decision_id,
    │            can call explain_decision to see which policy fired
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

**When AxonFlow cannot decide:** a rejected credential, a limit or a refusal blocks the tool call; an unreachable agent lets it run with a notice you see, or blocks it under `AXONFLOW_FAIL_MODE=closed`. PostToolUse never blocks. The full table is in [When AxonFlow cannot decide](#when-axonflow-cannot-decide).

---

## Where this kicks in during real coding

### 1. The MCP data-exposure problem

A developer connects an MCP server to a production database for debugging. Claude Code queries customer records. Results flow through the conversation with PII intact. Session logs exist but they aren't structured for compliance queries.

**With the plugin:** `check_policy` fires before the MCP query runs (SQL injection scan, policy scan), `check_output` scans the result for SSN / credit card / email / phone / API keys, and `audit_tool_call` records the full interaction with matched policies and decision ID.

### 2. The accidental production change

A developer types *"fix the database issue."* Claude Code picks a `Bash` tool and runs a migration against prod. The command ran because nothing stopped it.

**With the plugin:** a dynamic policy scoped to production patterns matches, the call is denied with a decision ID, and Claude surfaces the deny reason in the REPL. A developer can call `explain_decision` to see exactly which policy family triggered, without leaving the session; changing the verdict is an administrator's edit to the organization's policy.

### 3. The security-review block

A team wants to deploy Claude Code at scale and security says no: *"No policy enforcement on MCP queries, PII flows through conversations unchecked, bash commands aren't governed, audit trail isn't compliance-ready, no approval gates."*

**With the plugin:** every one of those gaps is filled at the plugin layer. The productivity surface doesn't change.

---

## Take a governed plugin rollout into production

Solo developers and self-serve teams can use the free 90-day [Plugin Evaluation License](https://getaxonflow.com/plugins/evaluation-license?utm_source=readme_plugin_claude_eval) to validate hook behavior and policy packs.

### See AxonFlow in Action

Videos covering different angles of the platform:

- **[Product demos: Platform + Fraud & Risk](https://getaxonflow.com/demo/?utm_source=github&utm_medium=readme&utm_campaign=product_demo&utm_content=axonflow-claude-plugin)** - runtime enforcement, HITL approvals, audit evidence, cost visibility, and agentic payment controls
- **[Community Quickstart walkthrough (2 min)](https://youtu.be/BSqU1z0xxCo)** - governed calls, PII blocking, Gateway Mode with LangChain/CrewAI, and MAP from YAML
- **[Architecture deep dive (12 min)](https://youtu.be/Q2CZ1qnquhg)** - how the control plane works, policy enforcement flow, and multi-agent planning
- **[Plugin setup and usage walkthrough](https://youtu.be/_dlnX_xLYmU)** - install AxonFlow and watch governance fire on real coding work (PII redaction, production-change guardrails, audit trail)

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

Org-wide policies are **Enterprise-only**, the actual upgrade trigger for plugin users. Session overrides are retired from AxonFlow v11.0.0 in every edition (see [the MCP tools](#decision-explainability--session-overrides-4)).

[Get a free Plugin Evaluation license](https://getaxonflow.com/plugins/evaluation-license?utm_source=readme_plugin_claude_eval)

---

## Privacy notice

**Read before installing.** AxonFlow [Community SaaS](https://docs.getaxonflow.com/docs/deployment/community-saas/) at `try.getaxonflow.com` is the zero-config endpoint the plugin uses if neither `AXONFLOW_ENDPOINT` nor `AXONFLOW_AUTH` is configured. In that mode, governed tool inputs (tool name + arguments) and outbound message bodies are checked by AxonFlow's policy enforcement endpoint. **Community SaaS is for early exploration only** — not for production workloads, regulated environments, real user data, personal data, or any other sensitive information. It is offered "as is" on a best-effort basis with no SLA, no warranties, and no commitment to retention, deletion, or incident-response timelines.

For any serious use, choose one of the following instead:

1. **[Self-host AxonFlow Community Edition](https://docs.getaxonflow.com/docs/deployment/self-hosted/)** — runs entirely on your infrastructure and keeps data within your boundary. Recommended for any real workload. The in-README quick start is in [Step 1](#step-1-install-the-axonflow-platform) below.
2. **Community Edition with an [Evaluation License](https://docs.getaxonflow.com/docs/deployment/evaluation-rollout-guide/)** — for production use with real users or clients on the open core; adds production-fit limits and license-gated features. Free 90-day [evaluation license](https://getaxonflow.com/plugins/evaluation-license).
3. **[AxonFlow Enterprise](https://docs.getaxonflow.com/docs/deployment/community-to-enterprise-migration/)** — production-grade governance, regulatory-grade controls, SLOs, and contractual commitments suitable for regulated industries. Contact [hello@getaxonflow.com](mailto:hello@getaxonflow.com).

To skip Community SaaS entirely: set `AXONFLOW_ENDPOINT` to a self-hosted AxonFlow URL. That alone flips the plugin into self-hosted mode — the Community SaaS auto-bootstrap is not attempted, and no env var is required. Get the AxonFlow platform from [getaxonflow/axonflow](https://github.com/getaxonflow/axonflow) and follow the [Getting Started](https://docs.getaxonflow.com/docs/getting-started/) guide for the Docker Compose setup. For air-gapped environments where AxonFlow is not yet reachable but you want to suppress the bootstrap attempt, set `AXONFLOW_COMMUNITY_SAAS=0`; set `AXONFLOW_TELEMETRY=off` to also disable the anonymous 7-day heartbeat.

LLM provider keys never leave the user's machine in any mode — Claude Code makes the LLM calls; AxonFlow only enforces policies and records audit trails.

---

## Install

This is a **three-step** install: stand up the AxonFlow platform, add the plugin to Claude Code, then point the plugin at the platform. The plugin alone does not enforce policy — its hook scripts are thin clients that talk to an AxonFlow agent gateway. If the platform is not installed and reachable, governed tool calls have nothing to evaluate against. **Skipping Step 3 is the most common mistake**: the platform is running locally but the plugin still falls back to Community SaaS because no `AXONFLOW_ENDPOINT` is configured.

### Step 1: install the AxonFlow platform

For any real workload, run AxonFlow on your own infrastructure via Docker Compose:

```bash
git clone https://github.com/getaxonflow/axonflow.git
cd axonflow && docker compose up -d

# verify
curl -s http://localhost:8080/health | jq .
```

Follow the [Getting Started](https://docs.getaxonflow.com/docs/getting-started/) guide for prerequisites (Docker Engine or Desktop, Docker Compose v2, 4 GB RAM, 10 GB disk) and the [Self-Hosted Deployment Guide](https://docs.getaxonflow.com/docs/deployment/self-hosted/) for production options. For production with real users or clients, run Community Edition with a free 90-day [Evaluation License](https://docs.getaxonflow.com/docs/deployment/evaluation-rollout-guide/) or [AxonFlow Enterprise](https://docs.getaxonflow.com/docs/deployment/community-to-enterprise-migration/).

> Skipping Step 1 makes the plugin fall back to the [Community SaaS](https://docs.getaxonflow.com/docs/deployment/community-saas/) endpoint at `try.getaxonflow.com` for early exploration only. **Do not skip Step 1 for any real workload** — see the [Privacy notice](#privacy-notice) above.

### Step 2: install the plugin

Add this repo as a custom marketplace (recommended):

```
/plugin marketplace add getaxonflow/axonflow-claude-plugin
/plugin install axonflow
```

Or load locally for testing:

```bash
git clone https://github.com/getaxonflow/axonflow-claude-plugin.git
claude --plugin-dir /path/to/axonflow-claude-plugin
```

> The plugin has been submitted to the official Anthropic marketplace (`anthropics/claude-plugins-official`) and is currently in Anthropic's review queue. Until it appears in `/plugin > Discover`, use one of the install methods above.

### Step 3: point the plugin at the platform

Without this step the plugin auto-registers with Community SaaS regardless of whether you ran Step 1 — it does not auto-detect a locally-running AxonFlow. Set `AXONFLOW_ENDPOINT` (and `AXONFLOW_AUTH` if you have credentials):

```bash
# Self-hosted local agent — that alone flips mode to self-hosted, no other env var needed
export AXONFLOW_ENDPOINT=http://localhost:8080

# Self-hosted remote agent with credentials
export AXONFLOW_ENDPOINT=https://axonflow.your-company.com
export AXONFLOW_AUTH=$(echo -n "your-client-id:your-client-secret" | base64)
```

Every hook invocation logs a one-line canary on stderr confirming the active mode:

```
[AxonFlow] Connected to AxonFlow at http://localhost:8080 (mode=self-hosted)
```

If the canary says `mode=community-saas` after you ran Step 1, the plugin is still hitting `try.getaxonflow.com` because Step 3 was skipped or `AXONFLOW_ENDPOINT` is unset. Fix Step 3 and reload.

## Activate Pro tier

Plugin Pro extends the Free baseline (3-day audit retention, 200 governed events / day, 2 active custom policies, 1 HITL approval per rolling 7d) to **30-day retention**, **2,000 events / day**, **unlimited active custom policies**, **unlimited HITL approvals**, and adds the **LLM cost pre-flight** tool (estimate token cost for a multi-step plan before it runs). 90-day window, one-time **$9.99 USD** payment, no auto-renewal, 14-day no-questions refund. See [getaxonflow.com/pricing](https://getaxonflow.com/pricing/) for the full breakdown and the Stripe buy button.

To activate Pro on an installed plugin:

1. **Find your client ID.** Run `/axonflow-status` from any Claude Code session. The output includes a `client_id=cs_<uuid>` line — that's the value Stripe Checkout needs to bind the license to your account. Copy it. (Same value the v1.4.x and earlier output called `tenant_id`; renamed for terminology consistency with the rest of AxonFlow in v1.5.0.)
2. **Buy at the pricing page.** Visit [getaxonflow.com/pricing](https://getaxonflow.com/pricing/) and click **Buy Plugin Pro — $9.99**. At Stripe Checkout, paste your `client_id` into the **AxonFlow tenant ID** custom field. (The Stripe form's field label is still "AxonFlow tenant ID" — same value, the label will be renamed in a future release.)
3. **Install the issued license token.** After checkout you'll receive an `AXON-...` license token by email. Activate it via `/axonflow-login <your-AXON-token>` (the slash command's argument is the token itself), or by setting `AXONFLOW_LICENSE_TOKEN=<your-AXON-token>` in the environment Claude Code runs in.
4. **Reload Claude Code.** The next governed call uses Pro-tier limits automatically. The plugin's status canary appends `Pro tier active` so you can verify at a glance.

If you lose the token (laptop reinstall, never archived the email), use `/axonflow-recover <your-email>` to request a magic link, then `/axonflow-recover-verify <recovery-token>` to mint fresh credentials against the same email.

### Check status

Run `/axonflow-status` from any Claude Code session to see your `client_id`, the resolved AxonFlow endpoint, and current tier (`Free` vs `Pro`):

```
OK  endpoint=https://try.getaxonflow.com
OK  client_id=cs_a1b2c3d4-...  (formerly tenant_id)
OK  tier=Free
OK  license_token=unset
OK  upgrade_url=https://getaxonflow.com/pricing/
    Paste your client_id above into the Stripe checkout custom field
    (currently labeled 'AxonFlow tenant ID' on the Stripe form).
```

The `client_id` is the value to paste into the Stripe checkout custom field (still labeled "AxonFlow tenant ID" on the Stripe form) when upgrading to AxonFlow Pro. The on-disk registration file at `~/.config/axonflow/try-registration.json` still uses the `tenant_id` JSON key for file-format compat — same value, two names during the v9 transition. The license token is always shown redacted (`set (AXON-...XXXX)`) — the full bearer credential is never printed, so the output is safe to screen-share or paste into a support ticket.

> **Tip:** the same information is available without spawning a shell — just ask Claude "what's my AxonFlow client ID?" (or "tenant ID" — both work) and it will call the agent-side `axonflow_get_tenant_id` MCP tool, which returns the same identifier under its original wire name, the server-resolved tier, and the upgrade URLs. Other agent-callable Pro-related tools include `axonflow_list_pro_features` ("what would I get if I upgraded?") and `axonflow_get_cost_estimate` (Pro-only LLM cost pre-flight). See [The 15 MCP tools Claude can call](#the-15-mcp-tools-claude-can-call) below.

### Free-tier limits and upgrade prompts

When the plugin's hooks hit a Free-tier cap (200 events/day, 2 active custom policies, 1 HITL approval per rolling 7d, or a Pro-only feature), the agent returns a structured upgrade envelope. The plugin parses it and prints a single-line nudge to stderr — for example:

```
[AxonFlow] Daily limit reached on Free tier (200 events). Pro raises this to 2,000/day. Resets at midnight UTC.
[AxonFlow] Upgrade: https://buy.stripe.com/bJe28qbztcdVchjdkw8k800
```

The plugin also stamps the shared back-off file (below). A request-rate limit (`daily_quota`, `per_minute`) blocks governed calls locally, with no request sent, for at most 300 seconds after it was stamped; then the plugin asks the platform again, which answers the limit again if it still holds. A feature or object-count limit (`feature_pro_only`, `active_policies`, `hitl_approvals_window`, `decision_list_size`) shows its nudge and blocks nothing beyond the call it answered. The upgrade nudge is shown at most once per UTC day so it doesn't spam every hook.

---

## Mode-specific reference

The recommended self-hosted path is covered in [Install Step 1](#step-1-install-the-axonflow-platform). Two more modes worth knowing about:

### Community SaaS — for early exploration only

The plugin's zero-config fallback when neither `AXONFLOW_ENDPOINT` nor `AXONFLOW_AUTH` is configured. The plugin registers a tenant with `try.getaxonflow.com` on first run and persists credentials at `~/.config/axonflow/try-registration.json` (mode `0600`).

**Use only for early exploration of the plugin's behaviour. Not for production workloads, regulated environments, real user data, personal data, or any other sensitive information.**

| What goes to `try.getaxonflow.com` | What does NOT |
|---|---|
| Tool name + arguments before each governed call | LLM provider API keys |
| Outbound message bodies before delivery (PII/secret scan) | Claude Code conversation history outside governed tools |
| Anonymous 7-day heartbeat (plugin version, OS, runtime) | Files outside the Claude Code runtime |

The endpoint runs against shared Ollama models, rate-limits at 20 req/min · 500 req/day per tenant, and is offered "as is" on a best-effort basis with no SLA, no warranties, no commitment to retention or deletion timelines, and may be modified or discontinued without notice. Read the [Try AxonFlow — Free Trial Server](https://docs.getaxonflow.com/docs/deployment/community-saas/) page for the full disclosure, including [data retention](https://docs.getaxonflow.com/docs/deployment/community-saas/#limitations-and-disclaimers) and [registration mechanics](https://docs.getaxonflow.com/docs/deployment/community-saas/#registration).

### Air-gapped: zero outbound

For environments where no outbound traffic is permitted at all — air-gapped labs, regulated networks, classified deployments — set both env vars before the Claude Code process starts:

```bash
export AXONFLOW_COMMUNITY_SAAS=0   # disable Community SaaS auto-bootstrap
export AXONFLOW_TELEMETRY=off      # disable the anonymous 7-day heartbeat
export AXONFLOW_ENDPOINT=http://your-internal-axonflow:8080
```

With both env vars set and `AXONFLOW_ENDPOINT` pointing at a same-network instance, no traffic leaves your environment.

---

## Configure

[Step 3](#step-3-point-the-plugin-at-the-platform) above covers `AXONFLOW_ENDPOINT` and `AXONFLOW_AUTH`. Other connection options:

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

# Optional: attribute governed requests to a specific developer so the
# customer portal's User column and audit filter show a real person instead
# of a synthetic id. See "Per-developer identity" below.
export AXONFLOW_USER_EMAIL=alice@your-company.com

# Optional (Enterprise): admin-minted per-user token for a VERIFIED
# {identity, role} — role-scoped access instead of asserted-label-only
# attribution. See "Per-user authorization token" below.
export AXONFLOW_USER_TOKEN=<token minted by your org admin>
```

When `AXONFLOW_AUTH` is unset and `AXONFLOW_ENDPOINT` is unset, the plugin defaults to AxonFlow Community SaaS — no further configuration needed.

### Per-developer identity (`AXONFLOW_USER_EMAIL`)

By default a self-hosted / Enterprise agent attributes every governed request to
the credential's tenant (a client-scoped synthetic id), so the customer portal's
**User** column shows the same value for the whole team. Set `AXONFLOW_USER_EMAIL`
to the developer's email and the plugin sends it as the `X-User-Email` header on
every governed call — the MCP connection and both hooks — so audit rows are
attributed to the individual and the portal can filter by teammate.

```bash
export AXONFLOW_USER_EMAIL=alice@your-company.com
```

Resolution precedence:

1. **`AXONFLOW_USER_EMAIL`** — the supported source, and the **only reliable
   path for a fleet**. Claude Code does not expose the logged-in Anthropic
   account email to plugins/hooks, so set this per developer via managed
   settings / MDM (fleet) or the shell profile (individual). A value that is
   set but blank/whitespace-only falls through to the git fallback.
2. **`git config user.email`** — a best-effort fallback used only when the env
   var doesn't resolve. The plugin first does a merged read from the hook's
   working directory (repo-local value wins; outside a repo git still returns
   the global value), then an explicit `--global` read that survives failures
   the merged read dies on (corrupt `.git/config`, deleted working directory).
   ⚠️ It still only resolves **if git is installed and a `user.email` is
   actually configured** — on a fresh machine or container image neither is a
   given — and it is the *git* identity, **not** the Anthropic account, so it
   can be silently wrong on shared machines or service accounts. It is also
   **repository-influenceable**: a repo obtained as an archive can ship a
   `.git/config` with an arbitrary `user.email` that this fallback would
   assert on your audit rows (a normal `git clone` cannot — config is not
   cloned). Because of that, git-sourced attribution is **never silent**: the
   hooks print a stderr notice naming the exact identity being asserted and
   its unverified source — at most once per day **per asserted identity**; a
   same-day identity change re-fires it immediately, and a second notice
   naming a different address is exactly the repo-influenced red flag to
   look for (same `AXONFLOW_IDENTITY_NOTICE=off` opt-out). Treat the
   fallback as a convenience default, not an authoritative identity, and do
   not rely on it for fleet rollouts or for trustworthy attribution.
3. **Unset** — no `X-User-Email` header is sent; the agent falls back to its
   client-scoped synthetic id (never a blank/broken User column). So that you
   can see *why* attribution degraded, the hooks print a one-line notice to
   stderr — at most once per day — naming the missing source and the fix.
   Suppress it with `AXONFLOW_IDENTITY_NOTICE=off` if your fleet intentionally
   runs without per-developer identity.

The resolved source is exported as `AXONFLOW_USER_IDENTITY_SOURCE`
(`env` | `git` | `none`) for scripting/debugging.

Identity here is *asserted*, not cryptographically verified — it improves audit
visibility; it is not an authentication boundary. For a **verified** per-user
identity with role-based access, see the per-user authorization token below.

### Per-user authorization token (`AXONFLOW_USER_TOKEN`)

`AXONFLOW_USER_EMAIL` is an asserted label; the **per-user token** is the
verified counterpart. On an Enterprise platform that validates per-user tokens
(enterprise#2929, first platform release after v9.9.0), an org admin mints a
token per developer (`POST /api/v1/admin/organizations/{org_id}/user-tokens`,
or OIDC tokens from your IdP), and the plugin sends it as the `X-User-Token`
header on every governed request — the MCP connection and both hooks. The
platform validates it (signature, expiry, revocation, org binding) and
resolves a **non-forgeable `{identity, role}`** for the developer: audit rows
attribute to the verified identity, and role-scoped features (e.g. who can
read the whole tenant's audit trail vs. only their own rows) key on the
validated role instead of treating every fleet developer identically.

Resolution precedence (mirrors the license-token discipline):

1. **`AXONFLOW_USER_TOKEN`** — set per developer via managed settings / MDM
   (fleet) or the shell profile (individual). Wins outright.
2. **`~/.config/axonflow/user-token.json`** — `{"token": "<minted token>"}`,
   written by your fleet's provisioning tooling. The file **must be `0600`**
   (owner read/write only); the plugin refuses a group/world-readable token
   file with a stderr warning rather than loading it silently:

   ```bash
   umask 077
   printf '{"token":"%s"}' "<minted token>" > ~/.config/axonflow/user-token.json
   chmod 600 ~/.config/axonflow/user-token.json
   ```

3. **Unset** — no `X-User-Token` header is sent (never an empty header) and
   requests are exactly what a pre-1.10 plugin sends; the platform keeps its
   least-privilege attribution path (`X-User-Email` label, own-rows access).

The token is a **credential**: the plugin never logs or echoes its value, and
a malformed candidate (whitespace/control/quote bytes — a mis-paste) is
dropped locally with a diagnostic instead of being sent. Note the platform
**fails closed** on a presented-but-invalid token (expired, revoked, minted
for a different org): governed calls are then denied until the token is
rotated or removed — the deny message names the token as the likely cause.
Rotation/revocation is admin-driven on the platform; re-provisioning the new
token to the developer's env/file is all the plugin needs.

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

## The 15 MCP tools Claude can call

In addition to automatic hooks, the agent's MCP server exposes **15 tools** Claude can call directly. All served by the platform at `/api/v1/mcp-server` — the plugin's `.mcp.json` just points Claude there. New platform tools are immediately available.

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
| `create_override` | **Retired from AxonFlow v11.0.0**: answers a tool error beginning `LEGACY_POLICY_WRITE_FROZEN: ` and creates nothing |
| `delete_override` | **Retired from AxonFlow v11.0.0**: answers the same tool error |
| `list_overrides` | List the overrides recorded for the caller's tenant (an unchanged read; from v11.0.0 an override changes no verdict) |

### Tenant identity & tier capability (5 — V1 Plugin Pro)

| Tool | Free access | Pro access |
|------|-------------|------------|
| `axonflow_get_tenant_id` | Visible + callable — returns tenant_id, server-resolved tier, upgrade URL | Same |
| `axonflow_list_pro_features` | Visible + callable — locked Pro feature list (5 differentiators + $9.99 / 90-day pricing) | Same |
| `axonflow_request_approval` | Visible + 1 per rolling 7d | Unlimited |
| `axonflow_create_tenant_policy` | Visible + 2 active max | Unlimited |
| `axonflow_get_cost_estimate` | Filtered out of `tools/list` — Pro-only | Visible + callable |

When a Free-tier cap is hit on these tools, the agent returns a structured upgrade envelope (same shape as the 429 daily-quota envelope) and the plugin surfaces the upgrade prompt to stderr — see [Free-tier limits and upgrade prompts](#free-tier-limits-and-upgrade-prompts).

**After a block:** the deny reason includes the `decision_id`; the developer asks Claude to call `explain_decision` to see which policy fired and why. **Session overrides are retired from AxonFlow v11.0.0:** no override changes a verdict, and a retry does not succeed because one was requested. What changes a verdict is an administrator's edit to the policy in the organization's typed policy document (a shipped system control is in its `system_controls` section), through `/api/v1/typed-policies`. The `create-override` and `revoke-override` skills explain this instead of promising an unblock.

---

## When AxonFlow cannot decide

Every governed call gets one of these answers. PreToolUse blocks through Claude Code's structured deny (`permissionDecision: "deny"`, the reason shown in the session). A notice that lets the call run goes in the hook JSON's `systemMessage`, which Claude Code shows you: Claude Code does not show a hook's stderr when the hook succeeds, so a stderr-only warning would be silent. PostToolUse never blocks; when it could not check an output it tells Claude not to use it (a governance alert) or passes it with a notice.

| AxonFlow's answer | PreToolUse | PostToolUse |
|---|---|---|
| A policy decision (a JSON-RPC result on any HTTP status but 401 and 429) | as decided: a deny blocks | a deny or a redaction is a governance alert |
| A result that decides nothing (no boolean `allowed`, or `isError`) | **blocked** | alert |
| **HTTP 401**, with or without a per-user token, and the cooldown it starts | **blocked**, quoting the agent; the cooldown blocks locally for `AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS` (300 by default), naming the seconds left and the file to delete | alert |
| A JSON-RPC `-32001` answer on any HTTP status but 429, with `AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1` (or `true`) | **runs ungoverned**, with a notice naming the switch | alert naming the switch |
| **HTTP 429**, with or without the Free-tier envelope, and a request-rate limit stamp | **blocked**, the limit named | alert |
| A refusal: a redirect, a 4xx other than 408 without a decision (402 and 413 included), a JSON-RPC error other than `-32603` / `-32700` | **blocked** | alert |
| The check request could not be built | **blocked** | alert |
| **No usable answer**: unreachable, timeout, 408, 5xx, `-32603` / `-32700`, an empty or unreadable body, not exactly one JSON document, `jq` or `curl` missing, and Community SaaS with no credential because the registration did not complete (no request is sent and no stamp written) | `AXONFLOW_FAIL_MODE` unset, empty or `open`: **runs**, with a `GOVERNANCE UNAVAILABLE` notice. Any other value: **blocked** | `open`: passes with the notice. Otherwise: alert |
| `scripts/lib/failure-posture.sh` missing (a broken install) | **blocked**, naming the file | alert, naming it |

- **`AXONFLOW_FAIL_MODE=open|closed`** decides only the no-usable-answer row. It is read case-insensitively, and any value other than unset, empty or `open` blocks, so a typo fails safe. It never loosens a 401, a 429, a refusal or a policy deny.
- **`AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1`** is an operator's break-glass for a `-32001` authentication error while a credential is being fixed. It is off by default, it covers only a single `-32001` answer, on any HTTP status but 429 (never a plain 401, a body of more than one JSON document, or the cooldown), and it stamps no cooldown; every call it lets through carries a notice naming it. The post hook does not run ungoverned under it: Claude is still told not to use the unchecked output, in an alert that names the switch. **On a community AxonFlow v11.0.0 agent the only live `-32001` is the MCP server's refusal of a client id the organization has not admitted** (once it has admitted its service-principal ceiling), so this switch lets an UNADMITTED client run ungoverned. The Codex plugin has no such switch; this one is Claude Code-only.
- **The shared back-off file** is `${XDG_CACHE_HOME:-$HOME/.cache}/axonflow/throttle-until`, one line, `<epoch> <limit_type>`. The Claude Code, Cursor and Codex hooks (and, on Linux, the OpenClaw plugin) read and write the same file, so a stamp written by one plugin can block another. This plugin honours an `auth_failure` stamp for its own configured cooldown (`AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS`, 300 seconds by default) after the file was written, whatever deadline the file carries, and a request-rate limit (`daily_quota`, `per_minute`) for at most 300 seconds after it was written (a stamp written more than 60 seconds in the future counts as past that); any other stamp blocks nothing here and is left on disk for the plugin that wrote it. The file is removed when its deadline passes. After fixing a credential, delete it to retry at once.
- **Nothing is skipped for lack of content.** A call whose input has nothing to check (an MCP call with no arguments, a NotebookEdit delete, an empty command) is checked as the tool's name plus the input's plain fields.
- **The audit record** a PostToolUse call sends carries `success` only when Claude Code said how the tool ended (a numeric `exitCode` or a boolean `success` in its response). Claude Code's Bash, Write and Edit responses carry neither, so those records carry no `success` field rather than claiming one.
- **An unreachable agent is never silent,** and a governed call on an unreachable agent is not a governed call: set `AXONFLOW_FAIL_MODE=closed` where running ungoverned is not acceptable.

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
│   ├── pre-tool-check.sh    # Policy enforcement before tool execution
│   ├── post-tool-audit.sh   # Audit + PII scan after execution
│   ├── mcp-auth-headers.sh  # Basic-auth header generation for MCP
│   └── telemetry-ping.sh    # Anonymous heartbeat (at most once per 7 days)
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

# The failure posture, with the real hook scripts, against a live AxonFlow
bash runtime-e2e/hook-failure-posture/test.sh
```

The smoke scenario feeds a destructive Bash command (`rm -rf / --no-preserve-root`), in the hook JSON Claude Code sends, through the plugin's `pre-tool-check.sh` against a running platform, and asserts the `permissionDecision: deny` shape naming the policy violation and the decision id. Exits 0 with `SKIP:` if no stack is reachable. Run in CI via `workflow_dispatch` when a reachable endpoint is configured.

No test or suite in this repository targets production Community SaaS by default: the ones that would write there SKIP unless `AXONFLOW_E2E_ALLOW_PRODUCTION=1` is set for the run.

For the broader validation story — explain-decision, audit-filter parity, cache invalidation — see the [Claude Code integration guide](https://docs.getaxonflow.com/docs/integration/claude-code/) and the [governance test scenarios](https://docs.getaxonflow.com/docs/testing/) documentation.

---

## Telemetry

Anonymous heartbeat at most once every 7 days per machine: plugin version, OS, architecture, bash version, AxonFlow platform version, the licence tier that platform reports about itself, deployment mode (`community_saas` / `self_hosted` / `unknown`), and endpoint type (`localhost` / `private_network` / `remote` / `unknown`). **Never** tool arguments, message contents, or policy data. The stamp file mtime advances only after the HTTP POST returns 2xx, so a transient network failure does not silence telemetry until the next window.

The licence tier sent is whatever the platform reported about itself, relayed verbatim. The plugin does not normalise, map, or restrict the value, so a transient state such as `starting`, or a tier name introduced after this plugin shipped, reaches the wire unchanged rather than being flattened into a fixed list. What is never read or sent: **no licence key, no expiry date, no seat count, and no customer or organisation name**. It is read from the `tier` field of the `/health` response the heartbeat already fetches to detect the platform version, so it costs no additional request, and it is omitted entirely whenever that probe does not answer with one.

Two further values are relayed on the same terms, from the same response: the platform's **edition** and the deployment mode the **platform reports about itself**. The second is deliberately separate from the `deployment_mode` above, which is this plugin's own classification of the endpoint it was pointed at — they answer different questions and routinely differ, so neither is written over the other. Both are omitted entirely whenever the platform does not report them, which is the case for every platform released before they existed. Any relayed value longer than 64 bytes — measured in bytes, not characters — is dropped whole rather than truncated, since a truncated value would be something the platform never said, and a value containing a NUL is dropped for the same reason.

The heartbeat does not follow HTTP redirects on either leg, and only a **2xx** counts on either leg. A redirected or erroring `/health` teaches the plugin nothing — its body is not read at all, even when it carries one — rather than relaying values from a response your platform never meant as an answer. A redirected or rejected checkpoint POST is not treated as a delivery: the 7-day stamp advances only on a 2xx, so neither can silence telemetry for a week on a ping that was never received.

Opt out: set `AXONFLOW_TELEMETRY=off` in the environment Claude Code runs in.

### Scope of `AXONFLOW_TELEMETRY=off`

`AXONFLOW_TELEMETRY=off` disables the anonymous heartbeat described above. On **self-hosted** and **in-VPC** deployments, that heartbeat is the only data the plugin sends to AxonFlow, so setting `=off` means we receive nothing. On **Community SaaS** (`try.getaxonflow.com`) the hosted service also processes operational data — registrations, audit logs, policy enforcement records, workflow state, plan data, and request-header metadata aggregated for usage analytics — as part of running the platform; that operational data flow is governed by the [Privacy Policy](https://getaxonflow.com/privacy/), not by `AXONFLOW_TELEMETRY`.

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
