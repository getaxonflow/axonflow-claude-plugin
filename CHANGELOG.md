# Changelog

## [Unreleased]

## [1.6.0] - 2026-06-10 — `/axonflow-login --self-hosted` Enterprise credential fallback + endpoint-gated Community-SaaS credential (no more Enterprise MCP 401)

### Fixed

- **MCP tool execution no longer 401s on self-hosted / Enterprise agents when a
  Community-SaaS registration is left on disk ([axonflow-claude-plugin#94](https://github.com/getaxonflow/axonflow-claude-plugin/issues/94)).**
  The inline `.mcp.json` `headersHelper` fell back to the Community-SaaS
  `~/.config/axonflow/try-registration.json` **regardless of endpoint**. With
  `AXONFLOW_AUTH` unset and a `cs_<uuid>` registration present (left over from
  any prior community-saas run), it base64-encoded that `cs_<uuid>:secret`
  credential and sent it to the Enterprise agent, which rejected it with
  `invalid license key prefix (expected AXON-)` → HTTP 401 → `/mcp` showed
  "axonflow failed" and no AxonFlow MCP tool could execute. The per-call hooks
  gate the Community-SaaS credential on `AXONFLOW_MODE=community-saas`, so they
  kept authenticating — exactly the "governs via hooks but can't execute MCP
  tools" asymmetry reported by a design partner. Fixes:
  - The inline `headersHelper` now only uses `try-registration.json` when the
    endpoint is Community-SaaS (`AXONFLOW_ENDPOINT` unset or a
    `try.getaxonflow.com` host). On a self-hosted/Enterprise endpoint it never
    sends the `cs_` credential.
  - **New durable Enterprise credential fallback** at
    `~/.config/axonflow/self-hosted-auth.json` (mode `0600`), read by BOTH the
    `headersHelper` and the hooks when `AXONFLOW_AUTH` is not in the
    subprocess env — so MCP auth is no longer solely dependent on the env
    reaching every subprocess (parity with the Community-SaaS and Pro file
    caches). Written by `/axonflow-login --self-hosted <org_id> <license_key>`.
    **Precedence: the `AXONFLOW_AUTH` env var always wins; the file is the
    fallback.**
  - A raw `"<org>:<key>"` `AXONFLOW_AUTH` (a common misconfig that 401s as
    `Basic <raw>`) is now normalized to the base64 the agent expects, on both
    the `headersHelper` and hook paths.
  - New `scripts/self-hosted-auth.sh` keeps the hooks and the `headersHelper`
    in credential parity. New unit coverage in `tests/test-mcp-headers.sh` and
    a real-claude-binary runtime test at
    `runtime-e2e/mcp-self-hosted-auth-fallback/` (asserts an MCP tool actually
    executes via the file fallback, and that the stale `cs_` credential never
    reaches the Enterprise agent). Community-SaaS behavior is unchanged.

## [1.5.3] - 2026-06-08 — Fix MCP server connection on self-hosted / Enterprise agents (no more "axonflow failed / OAuth 404") + actionable fail-closed deny

### Fixed

- **MCP server connection now works on self-hosted and Enterprise (in-VPC)
  agents.** `.mcp.json` previously set
  `"headersHelper": "${CLAUDE_PLUGIN_ROOT}/scripts/mcp-auth-headers.sh"`, but
  Claude Code does **not** expand `${CLAUDE_PLUGIN_ROOT}` (or any env var) in
  the `headersHelper` field — only in `command`, `args`, `env`, `url`, and
  `headers`. The helper therefore resolved to a non-existent path, never ran,
  and **no `Authorization` header was sent** — so the MCP connection fell into
  OAuth discovery and died on the agent's plaintext `404 page not found`,
  surfacing as `/mcp` → *"axonflow failed (HTTP 404: Invalid OAuth error
  response … Raw body: 404 page not found)"*. This hit **every** install
  (community and Enterprise) regardless of whether `AXONFLOW_AUTH` was set.
  `.mcp.json` now inlines a **self-contained, path-independent** header
  resolver that reads the credential from `AXONFLOW_AUTH` (Enterprise /
  self-hosted) or the Community-SaaS `try-registration.json`, plus the Pro
  `X-License-Token` (env or the 0600-guarded on-disk file) and
  `X-Axonflow-Client`. Verified end-to-end through the real `claude` binary:
  `/mcp` now shows **connected**, governed MCP tool calls work, and policy
  denials still block. `scripts/mcp-auth-headers.sh` is retained as the
  reference implementation.

### Changed

- **Auth-failure deny is now actionable.** When the agent rejects the policy
  pre-check with an authentication error (JSON-RPC `-32001`), the
  `PreToolUse` deny reason now names the exact env vars to set
  (`AXONFLOW_ENDPOINT` + `AXONFLOW_AUTH=base64(org_id:license_key)`) and links
  the integration docs, instead of the generic "Fix AxonFlow configuration".
  The posture stays **fail-closed** by default. A documented break-glass —
  `AXONFLOW_FAIL_OPEN_ON_AUTH_ERROR=1` — lets an operator keep working
  ungoverned while they fix the credential, emitting a loud stderr warning
  every time it fires (never a silent weakening). `-32601`/`-32602`
  (version-mismatch) denials get their own clearer message.

### Added

- **`runtime-e2e/self-hosted-enterprise-auth/`** — drives the real `claude`
  binary against a real self-hosted / Enterprise agent with a **real
  (non-demo) license**, asserting (a) `/mcp` connects + an MCP tool call is
  allowed + a destructive op is blocked, and (b) auth-missing fails **closed**
  with an actionable message — never the OAuth-404 and never a silent allow.
  It deliberately refuses to fall back to demo creds.
- **`tests/test-mcp-headers.sh`** — unit test pinning the inline
  `headersHelper`: valid JSON, no `${CLAUDE_PLUGIN_ROOT}` dependency
  (regression guard), and correct credential resolution from env / community
  file / none.

## [1.5.2] - 2026-05-22 — Separate auth-failure stamp file + JSON-RPC auth-error fail-closed carve-out + license-token cache-skip + `org_id` in telemetry heartbeat

### Added

- **`org_id` field in the telemetry heartbeat body.** Brings the Claude
  Code plugin's telemetry up to parity with the platform — every
  heartbeat now identifies which deployment-organization emitted it.
  Three sources in precedence order:
  1. The `ORG_ID` env var when set (the operator's explicit configuration
     on self-hosted-style deployments, or a forced override).
  2. The `tenant_id` from `~/.config/axonflow/try-registration.json`
     (the `cs_<uuid>` Community SaaS tenant identifier).
  3. The `local-dev-org` sentinel when neither is configured.

  Always emitted on the wire; older receivers ignore the field cleanly
  for backward compat. Honors `AXONFLOW_TELEMETRY=off` like every other
  heartbeat field. See
  [getaxonflow.com/privacy/](https://getaxonflow.com/privacy/) for the
  customer-facing commitment that covers this field.

### Fixed

- **Auth-failure credential-refresh nudge now uses a separate
  `~/.cache/axonflow/auth-failure-prompt-last-shown` stamp file**
  instead of sharing the envelope handler's
  `upgrade-prompt-last-shown` stamp. Before this fix, a tier-limit
  upgrade prompt earlier the same UTC day would silently suppress the
  credential-refresh nudge (and vice versa) — defeating the
  operator-visibility goal of the v1.5.1 throttle. The throttle file
  itself (`throttle-until`) was always written correctly; only the
  stderr nudge was suppressed.
- **HTTP 401 with a JSON-RPC `-32001` error body now routes through
  the fail-closed deny branch** in `pre-tool-check.sh` instead of the
  auth-storm throttle path. v1.5.1 had wired the auth-failure handler
  ahead of the JSON-RPC parser, which caused the documented `-32001`
  deny semantics to regress on the narrow intersection where the agent
  emits both an HTTP 401 status and a `-32001` body — operators with
  structurally wrong credentials saw 5 minutes of silent fall-open
  instead of a deny decision they could act on. The carve-out
  inspects the body's JSON-RPC code before invoking the throttle
  handler and skips it when code == `-32001`. Plain HTTP 401s
  (non-`-32001` body shape) still route through the throttle handler,
  so the v1.5.1 auth-storm prevention path is intact.
- **MCP server no longer fails to register when a self-hosted
  `AXONFLOW_AUTH` credential is paired with a stale on-disk Pro
  license token.** Previously, `resolve_license_token` always loaded
  `~/.config/axonflow/license-token.json` on top of any explicit
  `AXONFLOW_AUTH` credential the user had set for a self-hosted v9
  deployment. The plugin then emitted both an `X-License-Token` header
  (signed by Community SaaS) and Basic auth (a self-hosted credential
  the local platform expects) — the self-hosted platform could not
  validate the foreign-signed token, so the MCP server connection
  failed silently at auth. Symptom: `claude --plugin-dir` reported
  `mcp_servers: [{name: plugin:axonflow:axonflow, status: failed}]`
  and the spawned agent had no axonflow tools registered. When
  `AXONFLOW_AUTH` is set, the plugin no longer falls back to the
  on-disk cache. Operators can still opt in explicitly by exporting
  `AXONFLOW_LICENSE_TOKEN` (that path is unchanged).

### Changed

- **`scripts/telemetry-ping.sh` header comment** softened from "Anonymous
  telemetry heartbeat" to "Telemetry heartbeat" alongside the `org_id`
  addition — the operator-supplied `ORG_ID` on self-hosted-style
  deployments is not anonymized; only the `instance_id` and the
  `cs_<uuid>` Community SaaS identifier remain anonymous-by-design.

## [1.5.1] - 2026-05-20 — Throttle on HTTP 401 to prevent auth-storm retry loops

### Fixed

- **HTTP 401 from the AxonFlow agent now stamps a 5-minute throttle on
  the plugin's `~/.cache/axonflow/throttle-until` file**, so subsequent
  `PreToolUse` and `PostToolUse` hook fires short-circuit the network
  call locally instead of generating a fresh 401 each. Before this
  fix, every hook re-fired because the existing envelope handler only
  detected 429 / 403 and the script fell through with no back-off when
  credentials were invalid or expired — one customer observed
  716 × 401 in 24h against the audit endpoint from a single source IP.
  A new helper in `scripts/upgrade-prompt.sh` is wired into both hook
  scripts after the existing envelope handling. A once-per-UTC-day
  stderr prompt directs the operator to refresh credentials at
  https://getaxonflow.com/dashboard; subsequent 401s within the
  throttle window are silent. The throttle is self-clearing once the
  deadline passes — refreshing credentials before the cooldown expires
  has no penalty, the next governed call simply re-stamps if the new
  credentials are also rejected.

## [1.5.0] - 2026-05-19 — Terminology: `tenant_id` → `client_id` in user-facing output

### Changed

- **`/axonflow-status` output: `tenant_id` label is now `client_id`.**
  Same value, new user-facing term. Aligns the Claude Code plugin
  output with the rest of AxonFlow's v9 terminology (the `org_id`
  ↔ `client_id` ↔ deployment-license-identity three-identifier model).
  For this release, the output carries a parenthetical bridge note
  (`(formerly tenant_id)`) so existing users connect the old and new
  terms without surprise. The bridge note will be removed in v1.6.0.

  **Cosmetic only — no config change is required.** The on-disk
  registration file at `~/.config/axonflow/try-registration.json`
  continues to use the `tenant_id` JSON key (file-format compat with
  installed base); only the human-readable status output reads
  `client_id`. Wire-level `X-Axonflow-Client` header is unchanged. The
  agent-side MCP tool `axonflow_get_tenant_id` keeps its name
  (callable both as muscle-memory "what's my tenant ID?" and the new
  "what's my client ID?" — both return the same identifier).

  **Action required for users who scripted around the old output:** if
  your tooling greps for `tenant_id=cs_` in `/axonflow-status` stdout,
  update to grep for `client_id=cs_` (or use the underlying
  `~/.config/axonflow/try-registration.json` file which still carries
  the legacy key).

- **README install-flow examples** updated to use `client_id`
  terminology consistently. The "Activate Pro tier" walkthrough notes
  that Stripe Checkout's custom field is still labeled "AxonFlow
  tenant ID" until that form is updated separately.

## [1.4.0] - 2026-05-09 — Decision History API + policy_version recorded on every decision + telemetry simplification

### Added

- **`/axonflow-list-recent-decisions` slash command + skill** — surfaces the caller's recent governance decisions via the new `list_recent_decisions` MCP tool. Tier-throttled per the platform's Free/Pro window+limit; Free callers hitting the cap see the upgrade envelope rendered to the host.

### Telemetry

- **`AXONFLOW_TELEMETRY=off` is the sole opt-out** for the plugin heartbeat — same single-lever model as the SDKs.
- **Heartbeat payload v1 schema additions**: `telemetry_type: "plugin"`, `endpoint_type` (`localhost | private_network | remote | unknown`), `deployment_mode` (`self_hosted | community_saas | unknown`). Set `AXONFLOW_TRY=1` if your stack proxies a custom hostname into try.getaxonflow.com so heartbeats classify as `community_saas` correctly.

## [1.3.0] - 2026-05-07 — V1 Plugin Pro upgrade-prompt envelope + 5 new MCP tools surfaced

Companion plugin release to AxonFlow agent v7.7.0. Surfaces the V1
Plugin Pro structured upgrade envelope to the operator on Community
SaaS rate-limit hits and documents 5 new agent-callable MCP tools.

### Added

- **V1 Plugin Pro upgrade-prompt envelope handling** in both PreToolUse and
 PostToolUse hooks. When the agent returns a 429 (daily-quota) or 403
 (graduated / Pro-only) with the structured envelope shape, the plugin:
 - Parses `upgrade.wording` + `upgrade.buy_url` and prints a single-line
 nudge to stderr (e.g. `[AxonFlow] Daily limit reached on Free tier
 (200 events). Pro raises this to 2,000/day. Resets at midnight UTC.`).
 Surfaced at most once per UTC day so it doesn't spam every hook.
 - Honours `Retry-After` / `resets_at` by stamping a back-off file at
 `~/.cache/axonflow/throttle-until`. Subsequent hook fires fall open
 locally without re-hammering the agent until the deadline passes.
 Prevents the silent-retry pattern (581 retries in 18h pre-envelope)
 that motivated this work.
- **References to the 5 new agent-callable MCP tools** in the
 `axonflow-status` skill and the README. The agent can answer
 `"what's my tenant ID?"`, `"what would I get on Pro?"`, and related
 questions directly via:
 - `axonflow_get_tenant_id` — Free + Pro, no gate.
 - `axonflow_list_pro_features` — Free + Pro, locked feature list.
 - `axonflow_request_approval` — Free 1/7d rolling, Pro unlimited.
 - `axonflow_create_tenant_policy` — Free 2 active max, Pro unlimited.
 - `axonflow_get_cost_estimate` — Pro-only, hidden from Free `tools/list`.

 Auto-discovered via the existing MCP HTTP transport — no client-side
 registration needed. The skill notes that the AI should prefer these
 tools over equivalent shell scripts when both exist.

### Changed

- **README "Activate Pro tier" section** corrected to the locked V1
 numbers: 2,000 events/day (was 1,000), unlimited custom policies,
 unlimited HITL approvals, and the LLM cost pre-flight feature added.
- **README MCP-tools section** renumbered from "10 MCP tools" to "15 MCP
 tools" to include the new V1 Pro tier-identity / tier-capability tools.
- **`axonflow-status` skill — prefer the local `scripts/status.sh` over
 the MCP tool** for tenant_id / tier queries. The local script reads
 state directly (`~/.config/axonflow/try-registration.json`, the
 configured license token's JWT `exp` claim) and answers without an
 agent round-trip. Faster, works offline, and works exactly when the
 user typically asks ("the agent isn't reachable, what's my tenant
 ID for Stripe Checkout?"). The MCP tool stays as a documented
 fallback for the rare cases where server-truth matters (revocation,
 clock skew, server-side overrides).

### Internal

- the runtime test bundle — drives the plugin's real
 `axonflow_handle_envelope_response` against a live V1 envelope
 captured from a Free-tier tenant on `try.getaxonflow.com` past the
 200/day cap. The plugin handler is ready for both bare and
 JSON-RPC-wrapped envelope shapes (the latter is what the new V1 Pro
 MCP tools deliver); a current limitation is that the plugin's hook
 path calls `/api/v1/mcp-server` which doesn't yet route the
 daily-cap envelope through the same code path as
 `/api/v1/audit/tool-call` — pending an agent-side fix in a future
 v7.7.x release. The plugin code emits the same operator nudge as
 soon as the agent-side wiring lands.
- `tests/test-skill-status-prefers-local.sh` — content assertion that
 the `axonflow-status` SKILL.md's first numbered step references the
 local script path before any MCP tool reference. Wired into
 `.github/workflows/test.yml` so a future SKILL.md edit can't silently
 re-introduce the round-trip preference.

## [1.2.0] - 2026-05-06 — V1 paid Pro tier wire-up + X-Axonflow-Client header

Companion plugin release to platform v7.7.0. Surfaces the V1 SaaS Plugin
Pro tier — `/axonflow-login` to paste the license token, `/axonflow-status`
to see tier + expiry, plus the agent-side scope-validation header on
every governed request.

### Added

- **`X-Axonflow-Client: claude-code/<version>` header** on every governed
 agent request. Set automatically by the hook runtime; not configurable.
 Agents at v7.7.0+ derive request scope from this header and reject
 cross-quadrant token misuse (e.g. a SaaS Plugin Pro token paired with
 an SDK request) at the validator boundary. Older agents (pre-v7.7.0)
 ignore the header and continue to work unchanged.

- **`/axonflow-status` tier line now surfaces Pro license expiry.** The
 status output's `tier=` line parses the JWT `exp` claim from the
 configured Pro license token and renders one of three shapes: `Pro
 (expires YYYY-MM-DD, N days remaining)` when active, `Free (Pro
 expired YYYY-MM-DD — visit https://getaxonflow.com/pricing/ to renew)`
 when the token is on disk but its `exp` has passed (plugin will not
 forward an expired token), or `Free (no Pro license configured)`
 when no token is loaded. Lets users see their renewal date without
 hitting the agent and catches the lapsed-token state before their
 next governed call. Display only — JWT signature validation remains
 the platform's job. Adds a companion `skills/axonflow-status/SKILL.md`
 so the model knows when to invoke `/axonflow-status` from natural-
 language prompts ("when does my Pro license expire?").
- **`/axonflow-status` slash command.** Prints a one-screen status block
 with the resolved AxonFlow endpoint, the user's `tenant_id` (read from
 `~/.config/axonflow/try-registration.json`, or
 `$AXONFLOW_CONFIG_DIR/try-registration.json` when set), current tier
 (`Free` vs `Pro`), the redacted license-token preview
 (`set (AXON-...XXXX)`), and — for Free-tier users — the upgrade URL
 (`AXONFLOW_UPGRADE_URL` env or `https://getaxonflow.com/pricing/`). The
 `tenant_id` line is the value buyers paste into the Stripe checkout
 custom field when upgrading to AxonFlow Pro. Token output is always
 truncated to the last 4 characters — the full bearer credential is
 never printed, since `/axonflow-status` is a screen-share / support-
 ticket / log-pipe surface (mirrors the `axonflow-codex-plugin`
 token-leak fix).
- **V1 paid Pro tier wire-up.** Three new surfaces for the paid AxonFlow
 Pro tier:
 - `X-License-Token` HTTP header is now sent on every governed agent
 request when a paid token is configured. Resolution order is
 `AXONFLOW_LICENSE_TOKEN` env var first (wins), then
 `~/.config/axonflow/license-token.json` on disk. The agent's plugin-
 claim middleware validates the token and enriches the request
 context with Pro-tier metadata (extended retention, higher daily
 quotas, etc.). Free tier is unaffected — the header is simply
 absent and the middleware passes through.
 - `/axonflow-login <AXON-token>` slash command persists a paid
 token to `~/.config/axonflow/license-token.json` (mode 0600 inside a
 0700 directory; same security posture as `try-registration.json`).
 Validates the `AXON-` prefix locally before writing.
 - `/axonflow-recover <email>` and `/axonflow-recover-verify <token>`
 slash commands drive the platform's free-tier email-recovery flow
 end-to-end. Recovered credentials are persisted atomically to
 `~/.config/axonflow/try-registration.json` so the next governed call
 authenticates as the recovered tenant.
- **Mode-clarity canary extension.** When a paid token is configured the
 `pre-tool-check` hook emits an additional `[AxonFlow] Pro tier active
 (X-License-Token configured)` line on stderr alongside the existing
 `[AxonFlow] Connected to AxonFlow at <URL> (mode=...)` canary.
- **Two new runtime tests.** A test bundle proves the
 `X-License-Token` header reaches the wire across all three resolution
 modes (env, file, absent) via a Python `http.server` capture proxy.
 the runtime test bundle drives the recover / recover-verify slash-
 command helpers against a live community-saas agent + DB; SKIPs
 cleanly when no compatible stack is reachable.

### Fixed

- **Upgrade-pointer URL aligned with the canonical pricing page.** `AXONFLOW_UPGRADE_URL` default (the URL surfaced by `/axonflow-status` and `scripts/status.sh` to free-tier users, plus embedded in the `tier=Free (Pro expired ... — visit ... to renew)` line) is now `https://getaxonflow.com/pricing/`. The previous default `https://getaxonflow.com/pro` returned 404 — that page was referenced in PRDs but never built. The pricing page already resolves and carries the Plugin Pro $9.99 tier card with the Stripe buy button, so plugin status output now points free-tier users at a working URL. Override via `AXONFLOW_UPGRADE_URL` env var if needed. Same fix landed in companion plugin releases (openclaw-plugin v2.2.0, cursor-plugin v1.2.0, codex-plugin v1.2.0).
- **`/axonflow-recover-verify` error output**: when the platform returned
 a 4xx with the standard error envelope `{"error":{"code":N,"message":"."}}`,
 the script previously echoed the whole nested object as JSON instead
 of the human-readable message. Replay-rejected tokens now surface as
 `ERR 401 Recovery token has already been used` rather than a stringified
 JSON blob.
- **Runtime-e2e false negatives on developer laptops.** Both
 the runtime test bundle and
 the runtime test bundle were tripping the agent's in-memory IP
 rate limiter (5 calls/hour/IP, shared by `/api/v1/register` and
 `/api/v1/recover`) after a few iterations against `localhost`. Tests
 now spoof a unique `X-Forwarded-For` per run. The license-token
 middleware probe also moved from `/api/request` (which has its own
 tenant-credential 401 path that masked the middleware's verdict) to
 `/api/v1/register` so a 401 cleanly attributes to the
 PluginClaimMiddleware.

## [1.1.0] - 2026-05-04 — 5 governance skills + 5 slash commands

### Added

- **5 agent-callable governance skills.** Claude Code agents can use
 AxonFlow's read-side governance surface autonomously during a
 conversation via skills: `audit-search`, `explain-decision`,
 `list-overrides`, `create-override`, `revoke-override`.
- **5 governance slash commands.** Human-driven counterparts:
 `/axonflow-audit-search`, `/axonflow-explain-decision`,
 `/axonflow-list-overrides`, `/axonflow-create-override`,
 `/axonflow-revoke-override`.

## [1.0.0] - 2026-04-29 — Production, quality, and security hardening — upgrade encouraged

**Upgrade strongly recommended.** Over the past month we've shipped substantial production, quality, and security hardening across the AxonFlow plugin and platform — upgrade to the latest version for a more secure, reliable, and bug-free experience.

**Security highlights from this release cycle:**
- **Plugin cache and credential-file permission hardening** (this release). `~/.config/axonflow/` and `~/.cache/axonflow/` are tightened to mode `0700` on every invocation (was: only set on creation, leaving pre-existing world-readable directories unchanged); `try-registration.json` is written with mode `0600`. Pre-existing world-readable credential files are detected and refused on first load. Documented in [`GHSA-qgqh-qcq7-hqhm`](https://github.com/getaxonflow/axonflow-claude-plugin/security/advisories/GHSA-qgqh-qcq7-hqhm).
- **Cross-platform bootstrap reliability** (this release). macOS Community-SaaS bootstrap was silently no-op'ing because `flock(1)` is Linux-only; now uses a portable `mkdir`-based atomic lock with stale-lock reclamation, so first-install registration runs on macOS too.
- **Telemetry opt-out reliability** (this release). `DO_NOT_TRACK` was unreliable because Claude Code itself injects `DO_NOT_TRACK=1` into hook subprocesses regardless of user intent; the canonical opt-out is now `AXONFLOW_TELEMETRY=off`, an AxonFlow-scoped signal hosts can't unilaterally set.

The full set of platform-side security fixes shipped alongside this release — including multi-tenant isolation in MAP execution, cross-tenant audit-log isolation, and SQLi enforcement on the Community SaaS endpoint — is documented in the consolidated platform advisory [`GHSA-9h64-2846-7x7f`](https://github.com/getaxonflow/axonflow/security/advisories/GHSA-9h64-2846-7x7f).

**Reliability and bug-fix highlights:**
- **7-day delivered-heartbeat with stamp-on-success** (this release). Telemetry stamp advances only after the POST returns 2xx, so a transient network failure no longer silences telemetry until the next 7-day window. Concurrent invocations are de-duplicated by an in-flight gate.
- **Mode-clarity canary log line** on every hook init (this release). Stderr emits `[AxonFlow] Connected to AxonFlow at <URL> (mode=...)` and a PR-blocking CI gate asserts the canary matches the actual outbound destination, guarding against silent endpoint drift.
- **PR-blocking install-to-use smoke against the live community stack** (this release). Catches plugin-side regressions against `try.getaxonflow.com` before they reach a user's terminal.

### BREAKING

- **`DO_NOT_TRACK` is no longer honored as an AxonFlow telemetry opt-out.** Use `AXONFLOW_TELEMETRY=off` instead. Host tools and CLIs commonly inject `DO_NOT_TRACK=1` regardless of user intent, which makes it unreliable as a signal.

### Added

- **First-run Community-SaaS bootstrap** — plugin connects to AxonFlow Community SaaS at `https://try.getaxonflow.com` when neither `AXONFLOW_ENDPOINT` nor `AXONFLOW_AUTH` is set. Registers via `/api/v1/register` on first run and persists `{tenant_id, secret, expires_at, endpoint}` to `~/.config/axonflow/try-registration.json` (mode 0600 inside a 0700 directory). Refuses to load a registration file with non-0600 permissions. HTTP 429 → 1-hour backoff. Existing self-hosted installs (`AXONFLOW_ENDPOINT` or `AXONFLOW_AUTH` set) are honoured untouched.
- **Mode-clarity canary** on every hook init: `[AxonFlow] Connected to AxonFlow at <URL> (mode=community-saas|self-hosted)` on stderr. A CI gate parses this canary and asserts it matches the actual outbound destination.
- **One-time setup disclosure** on first Community-SaaS connection. Stamped at `~/.cache/axonflow/claude-code-plugin-disclosure-shown` so it fires exactly once per install.
- **Plugin/platform version compatibility check** (`scripts/version-check.sh`). Queries the agent's `/health` endpoint and warns if the plugin runtime is below the platform's expected floor. Skippable via `AXONFLOW_PLUGIN_VERSION_CHECK=off`.

### Changed

- **Telemetry switched to a 7-day delivered-heartbeat.** At most one anonymous ping per environment every 7 days, with the stamp advanced only after the POST returns 2xx — a transient network failure doesn't silence telemetry until the next window. Concurrent invocations are de-duplicated by an in-flight gate.

### Fixed

- The `DO_NOT_TRACK=1 is deprecated.` warning is no longer emitted on every hook invocation when `DO_NOT_TRACK=1` is set.
- Telemetry heartbeat now correctly classifies Community-SaaS sessions (was tagged `production` because the bootstrap-injected `AXONFLOW_AUTH` shadowed the resolver, sending `/health` probes to localhost and `platform_version=null` with the wrong `deployment_mode`).
- Bootstrap and heartbeat now run on macOS — `flock(1)` isn't on stock macOS, so the in-flight lock falls back to a `mkdir`-based atomic lock with stale-lock reclamation when `flock` is unavailable.

### Security

- `~/.config/axonflow/` and `~/.cache/axonflow/` permissions tightened to `0700` on every invocation (was: only set on creation via `mkdir -m 0700`, which left existing 0755 dirs unchanged).

## [0.5.2] - 2026-04-22

### Deprecated

- `DO_NOT_TRACK=1` as an AxonFlow telemetry opt-out — scheduled for removal after 2026-05-05 in the next major release. Use `AXONFLOW_TELEMETRY=off` instead. The plugin's `telemetry-ping.sh` emits a one-time stderr warning when `DO_NOT_TRACK=1` is the active control and `AXONFLOW_TELEMETRY=off` is not also set.

## [0.5.1] - 2026-04-19

### Added

- **Smoke E2E scenario** at the e2e test suite — runs
 `pre-tool-check.sh` against a reachable AxonFlow stack and asserts the
 hook returns `permissionDecision: deny` with Plugin Batch 1
 richer-context markers in the reason text. Exits 0 (`SKIP:`) when no
 stack is reachable.
- **`.github/workflows/smoke-e2e.yml`** — `workflow_dispatch` triggered job running the smoke scenario.
 Requires an operator-supplied endpoint (GitHub-hosted runners have no
 local stack), so not wired to PR events — PR smoke gating needs a
 self-hosted runner with a live stack.

Full install-and-use matrix is exercised in the platform integration tests.

## [0.5.0] - 2026-04-18

### Added

- **Richer block context in hook responses.** When the AxonFlow platform is
 v7.1.0+, block responses returned to Claude Code now include the
 `decision_id`, `risk_level`, and override availability. Users hitting a
 block see either `[decision: <id>, risk: <level>, active override: <ov>]`
 or a hint to call the `explain_decision` MCP tool. Older platforms see
 the prior terse message — fields are omitted when not returned.
- **Access to platform MCP tools** `explain_decision`, `create_override`,
 `delete_override`, `list_overrides` — exposed by the agent's MCP server.
 Agents can call these from within Claude Code via the MCP client.

### Compatibility

Companion to platform v7.1.0 and SDKs at v5.4.0 / v6.4.0. Back-compatible
with older platforms — enriched fields are absent, and the hook falls back
to the v0.4.0 block-reason format.

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
