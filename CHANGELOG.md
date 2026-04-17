# Changelog

## [0.5.0] - 2026-04-17 — Plugin Batch 1: Richer Approval Context

### Added

- **Richer block context in hook responses.** When the AxonFlow platform is
  v7.1.0+, block responses returned to Claude Code now include the
  `decision_id`, `risk_level`, and override availability. Users hitting a
  block see either `[decision: <id>, risk: <level>, active override: <ov>]`
  or a hint to call the `explain_decision` MCP tool. Older platforms see
  the prior terse message — fields are omitted when not returned.
- **Access to platform MCP tools** `explain_decision`, `create_override`,
  `delete_override`, `list_overrides` — already exposed by the agent's MCP
  server (no plugin change required to surface them). Agents can call these
  from within Claude Code via the MCP client once the platform supports them.

### Compatibility

Companion to platform v7.1.0 (ADR-042 + ADR-043) and SDKs at v5.4.0 /
v6.4.0. Back-compatible with older platforms — enriched fields are
absent, and the hook falls back to the v0.4.0 block-reason format.

## [0.4.0] - 2026-04-16

### Added

- **Anonymous telemetry ping** on first hook invocation. Sends plugin version, OS, architecture, bash version, and AxonFlow platform version to `checkpoint.getaxonflow.com`. No PII, no tool arguments, no policy data. Fires once per install (stamp file guard at `$HOME/.cache/axonflow/claude-code-plugin-telemetry-sent`). Opt out with `DO_NOT_TRACK=1` or `AXONFLOW_TELEMETRY=off`.

### Fixed

- **UTF-8 safe content truncation.** Write and Edit content extraction now uses character-level `cut -c1-2000` instead of byte-level `head -c 2000`. Prevents splitting multi-byte UTF-8 sequences (emoji, accented characters) at the truncation boundary, which could produce malformed JSON.
- **Consistent curl error reporting.** `post-tool-audit.sh` now uses `-sS` (silent + show errors) matching `pre-tool-check.sh`, instead of bare `-s` which silently swallowed curl-level errors.

### Changed

- **Hook timeout increased from 10s to 15s.** Provides sufficient buffer above the 8s default curl timeout for bash overhead and telemetry. Prevents premature hook termination on slower networks.

### Security

- Updated SECURITY.md timestamp to April 2026.

## [0.3.1] - 2026-04-10

### Added

- **Decision-matrix regression tests** for the v0.3.0 hook fail-open/fail-closed behavior. The v0.3.0 release only added a single stderr-string assertion update; the new branches (JSON-RPC -32601 method-not-found, -32602 invalid-params, -32603 internal, -32700 parse, and unknown error codes) were completely untested. This release adds mock-server cases for every branch so the decision matrix is now covered end-to-end. Claude Code's hook protocol uses JSON output with `permissionDecision: deny` instead of an exit-code `block`, so the test assertions check the JSON body for `"deny"` + `"governance blocked"` on fail-closed branches.

## [0.3.0] - 2026-04-08

### Changed

- **Hook fail-open/fail-closed hardening.** `scripts/pre-tool-check.sh` now distinguishes curl exit code (network failure) from HTTP success with an error body. Fail-closed (`permissionDecision: deny`) only on operator-fixable JSON-RPC errors: auth failures (-32001), method-not-found (-32601), and invalid-params (-32602). Fail-open (exit 0, allow) on everything else: curl timeouts/DNS failures/connection refused, empty response, server-internal errors (-32603), parse errors (-32700), and unknown error codes. Prevents transient governance infrastructure issues from blocking legitimate dev workflows while still catching broken configurations.

---

## [0.2.0] - 2026-04-06

### Added

- `AXONFLOW_TIMEOUT_SECONDS` environment variable to tune Claude Code hook HTTP timeouts for remote or high-latency AxonFlow deployments.
- Plugin logo for marketplace and directory listings.
- `SECURITY.md` with plugin-specific vulnerability reporting guidance.

### Changed

- README now clarifies that the Claude Code plugin itself does not send direct telemetry pings; telemetry settings apply to the underlying AxonFlow deployment and SDKs.

### Security

- Pinned all GitHub Actions to immutable commit SHAs to prevent supply chain attacks.
- Added Dependabot configuration for weekly GitHub Actions updates.
- Added explicit `permissions: contents: read` to test workflow (least privilege).

## [0.1.0] - 2026-04-05

### Added

- MCP server integration with 6 governance tools: `check_policy`, `check_output`, `audit_tool_call`, `list_policies`, `get_policy_stats`, `search_audit_events`
- Automatic PreToolUse hook: evaluates tool inputs against AxonFlow policies before execution. Blocks dangerous commands, reverse shells, SSRF, credential access, path traversal.
- Automatic PostToolUse hook: records tool execution in AxonFlow audit trail and scans output for PII/secrets. Scans Bash redirect commands (`echo ... > file`) when stdout is empty.
- Audit logging for blocked attempts: denied tool calls are recorded in the audit trail for compliance evidence.
- Fail-open on network failure, fail-closed on auth/config errors.
- Governed tools: `Bash`, `Write`, `Edit`, `NotebookEdit`, and all MCP tools (`mcp__*`).
- `scripts/mcp-auth-headers.sh` — auth header generator for MCP server connection. Supports community mode (no auth) and enterprise mode (Basic auth via `AXONFLOW_AUTH`).
- `tests/E2E_TESTING_PLAYBOOK.md` — comprehensive testing playbook with 12 test cases covering hooks, MCP tools, integration activation, and edge cases.
- 21 regression tests with mock MCP server (`tests/test-hooks.sh`), 18 live-mode tests against AxonFlow.
- CI workflow: shell syntax check, regression tests, plugin structure validation.

### Configuration

- `AXONFLOW_ENDPOINT` — AxonFlow Agent URL (default: `http://localhost:8080`)
- `AXONFLOW_AUTH` — Base64-encoded `clientId:clientSecret` for Basic auth
- `CLAUDE_PLUGIN_ROOT` — must be set when using `--plugin-dir` (Claude Code does not set this automatically)
- No LLM provider keys required — Claude Code handles LLM calls, AxonFlow only enforces policies.

### Architecture

Uses `headersHelper` for MCP server authentication (Claude Code's HTTP MCP client requires this instead of static headers). Matches the OpenClaw plugin pattern:

| OpenClaw Hook | Claude Code Hook | Behavior |
|---|---|---|
| `before_tool_call` | PreToolUse | Policy check before execution |
| `after_tool_call` | PostToolUse | Audit trail recording |
| `message_sending` | PostToolUse | PII/secret scanning on output |
