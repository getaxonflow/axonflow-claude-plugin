# Changelog

## [Unreleased]

### Changed

- **`audit_tool_call` now sends `caller_name` instead of `tool_type` to identify the calling plugin** (axonflow-enterprise#2912, sub-issue of epic #2905). `tool_type` was misleadingly named — it was never a tool classification, it identified WHICH CLIENT made the call. The platform side (axonflow-enterprise#2953 — implemented, not yet merged at the time of this change) adds the correctly-named `caller_name` field for this purpose; `tool_type` still works as a legacy fallback on platforms that have it, but is deprecated. Updated both `audit_tool_call` send sites — `scripts/post-tool-audit.sh` (PostToolUse) and `scripts/pre-tool-check.sh` (the blocked/redacted PreToolUse audit POSTs) — so every `audit_tool_call` call from this plugin now sends `caller_name: "claude_code"` instead of `tool_type`. **Do not deploy this version ahead of axonflow-enterprise#2953**: since this is a straight field swap rather than a dual-send, a platform that hasn't upgraded yet won't recognize `caller_name` and will lose caller attribution (falling back to "unknown"/default) until it does.

## [1.10.0] - 2026-07-16 — per-user authorization token (X-User-Token) on every governed request

### Added

- **The plugin now sends the admin-minted per-user token as `X-User-Token` on every governed request** (axonflow-enterprise#2935, epic #2919). The platform's fleet plane authenticates the *tenant* with the shared Basic credential; the per-user token additionally yields a **validated, non-forgeable `{identity, role}`** for the developer behind the session (`authenticateMCPServerRequest` → `extractPerUserToken` on the platform, shipped in enterprise#2929), which per-user read scoping (enterprise#2922) and audit attribution key on. Covered send surfaces — all four header-assembly paths:
  - `.mcp.json` inline `headersHelper` (MCP `tools/call` plane),
  - `scripts/mcp-auth-headers.sh` (the readable reference impl, kept in sync),
  - `scripts/pre-tool-check.sh` (PreToolUse `check_policy` + the blocked/redacted `audit_tool_call` POSTs),
  - `scripts/post-tool-audit.sh` (PostToolUse `audit_tool_call` + `check_output`).
- **Resolution order** (new `scripts/user-token.sh`, mirrors the license-token discipline): `AXONFLOW_USER_TOKEN` env var (managed settings / MDM env block — wins) → `~/.config/axonflow/user-token.json` (`{"token": "<minted token>"}`). The file is **0600-guarded**: non-0600 permissions are rejected with a stderr warning, never loaded silently. Tokens are minted by an org admin via `POST /api/v1/admin/organizations/{org_id}/user-tokens` (enterprise#2930).
- **Strictly additive and conditional**: when no token is configured, the header is omitted entirely (never empty) and every request is byte-identical to a 1.9.x plugin — the platform keeps its existing least-privilege attribution path. `X-User-Email` attribution is unchanged and still ships alongside the token.
- **Wire-safety guard, never logged**: a candidate token containing whitespace, control bytes, quotes, or backslashes is dropped locally with a diagnostic that never prints the value — the platform fails closed on a presented-but-invalid token, so sending a mangled credential would turn every governed call into an auth denial. For the same reason, the hooks' `-32001` fail-closed deny message now names a configured per-user token as a likely cause (expired / revoked / wrong org) instead of only pointing at `AXONFLOW_AUTH`.
- Tests: `tests/test-user-token.sh` (helper unit + reference-impl wire shape), token legs in `tests/test-mcp-headers.sh` (the REAL inline, configured + unconfigured + 0600-rejection), `tests/test-user-token-header-wire.sh` (drives the ACTUAL hooks against a header-capturing agent, asserting present-when-configured / absent-when-not on both planes), and `runtime-e2e/user-token/` (live-stack, no mocks).

### Fixed

- **Inline `.mcp.json` token resolver aligned with `scripts/user-token.sh` on the malformed-env + valid-file combo** (#108, pre-release corrective to the feature above). The inline `headersHelper` read the 0600 `user-token.json` fallback only when `AXONFLOW_USER_TOKEN` was *empty*, so a malformed (non-empty, wire-unsafe) env token suppressed the file read and was then dropped by the strip-check — no `X-User-Token` on the MCP plane, while the hooks' `resolve_user_token` dropped the same malformed env candidate and sent the valid file token. The inline now validates the env candidate FIRST and falls back to the 0600 file when it is missing OR dropped, strip-checking the file value too — exactly `resolve_user_token`'s semantics. The full env×file combo matrix is pinned on both resolvers (`tests/test-user-token.sh` + `tests/test-mcp-headers.sh`) and a live cross-plane equivalence leg was added to `runtime-e2e/user-token/`.

## [1.9.1] - 2026-07-09 — fix: report the real plugin version on the wire (plugin.json was stuck at 1.7.0)

### Fixed

- **The plugin now reports its actual version in the `X-Axonflow-Client` header.** `.claude-plugin/plugin.json` — the file `scripts/client-header.sh` reads to build `claude-code-plugin/<version>` — was left at `1.7.0` while the v1.8.0 and v1.9.0 releases bumped only `marketplace.json` and the changelog. As a result every 1.7.0 / 1.8.0 / 1.9.0 install reported itself as `1.7.0`, collapsing three releases into a single telemetry bucket and comparing against the platform floor in `version-check.sh` as if it were 1.7.0. plugin.json is now bumped in lockstep with the release.
- **The MCP `tools/call` plane now reports the version too.** The inline `X-Axonflow-Client` header in `.mcp.json` hardcoded `claude-code-plugin` with no version, so every governed MCP tool call was version-less on the wire — the same telemetry blind spot as the hook plane, just on a different plane. It now emits `claude-code-plugin/<version>`.

### Added

- **Version-alignment CI gate** (`scripts/validate-version-alignment.sh` + `.github/workflows/version-alignment.yml`): the build fails unless `plugin.json`, both `marketplace.json` version fields, the `.mcp.json` MCP-plane client header, and the top `CHANGELOG.md` entry all match. This makes the on-the-wire version (on both the hook and MCP planes) incapable of drifting from the released version again — the same discipline the platform and SDK manifests already enforce.

## [1.9.0] - 2026-07-06 — identity hardening: control-byte sanitizer + non-silent git-sourced attribution notice

### Security

- **Complete control-byte stripping in the identity sanitizer**
  (axonflow-enterprise#2842; hardens the #2836 work below before it ships).
  `_sanitize_user_email` stripped CR/LF/quote/backslash but not the other C0
  control bytes — a `git config user.email` carrying a raw FF (0x0c), VT
  (0x0b), or DEL (0x7f) survives git reads AND survived sanitization. The
  `.mcp.json` inline headersHelper assembles its headers JSON with `printf`
  (not jq), so a raw FF/VT (illegal inside a JSON string) landed unescaped
  and Claude Code rejects the malformed value — the axonflow MCP connection
  breaks, triggerable by repository contents alone. DEL is legal JSON but an
  RFC 7230-illegal header byte; it and the other raw bytes were forwarded
  into the HTTP headers and `audit_logs` on the hook planes. The sanitizer
  (sourced helper AND
  both inline `tr` calls) now strips `[:cntrl:]` plus space/quote/backslash —
  verified against BSD, GNU, and busybox tr; lossless for real addresses.
  (NUL needs no dedicated path: git truncates a config value at the NUL and
  command substitution drops NUL bytes — pinned in tests.)
- **Git-sourced attribution is no longer silent**
  (axonflow-enterprise#2842). The git fallback adopts the merged-read
  `user.email` (repo-local wins), which a repository's local configuration
  can influence — a repo shipped as an archive can carry a `.git/config`
  with an attacker-chosen address, silently redirecting the portal's User
  attribution (a normal `git clone` cannot: config is not cloned). Fully
  preventing this would break the legitimate per-repo git-identity workflow,
  so the merged read is KEPT and the silent property is removed instead:
  whenever attribution resolves from git, the hooks emit a once-per-UTC-day
  stderr notice naming the exact identity being asserted and stating that it
  is unverified and repo-influenceable — and the throttle is keyed on the
  asserted identity, so a SAME-DAY identity switch re-fires immediately (an
  earlier notice for the developer's own address cannot swallow a later
  attacker-influenced one). `AXONFLOW_USER_EMAIL` (managed settings / MDM)
  remains the only trustworthy source. Separate throttle stamp from the
  identity-absent notice; same `AXONFLOW_IDENTITY_NOTICE=off` opt-out;
  hooks-only (headersHelper stderr is not surfaced by Claude Code).
  Tests: control-byte matrix in `tests/test-user-identity.sh` +
  `tests/test-mcp-headers.sh` (the REAL inline, driven from a repo whose
  repo-local `user.email` carries FF/VT/DEL and NUL); git-notice
  fire/throttle/opt-out + repo-local-vs-global policy pins;
  `tests/test-user-email-header-wire.sh` asserts the REAL pre-tool hook
  sends the git identity AND fires the notice; `runtime-e2e/
  developer-identity/` grew a control-byte leg (cleaned address lands in
  `audit_logs`, raw byte stored nowhere) and asserts the git leg's notice
  against a live stack.

### Changed

- **Hardened per-developer identity resolution on the identity-absent path**
  (axonflow-enterprise#2836, epic #2832). v1.8.0's `git config user.email`
  fallback was a single merged read from the hook's working directory, which
  silently resolved nothing when the repo's `.git/config` was corrupt or the
  working directory had been deleted — and when nothing resolved, the plugin
  degraded to the client-scoped synthetic id without telling anyone (the
  exact way an unconfigured fleet goes unnoticed). `scripts/user-identity.sh`
  now:
  - falls back from the merged read to an explicit `git config --global
    user.email` read that survives a corrupt `.git/config` and a deleted cwd
    (a dubious-ownership repo needs no rescue: git itself skips the repo-local
    config and the merged read returns the global value — pinned in tests via
    git's `GIT_TEST_ASSUME_DIFFERENT_OWNER` knob);
  - probes standard install locations for git when the hook PATH is stripped
    (guarding against the macOS `/usr/bin/git` Xcode shim popping a GUI dialog
    when no toolchain is installed). The probe targets git specifically;
    resolution still assumes coreutils on PATH, which the hooks already
    require (they exit before resolution when jq/curl are missing);
  - treats a set-but-blank `AXONFLOW_USER_EMAIL` as unset and falls through to
    the git fallback instead of silently suppressing the header — a behavior
    change for that input class (previously the header was simply omitted);
  - emits a **once-per-UTC-day stderr diagnostic** when no identity resolves,
    naming the reason and the fix (`AXONFLOW_USER_EMAIL` via managed settings /
    MDM is the reliable fleet path). The throttle stamp falls back to a
    per-uid tmp dir when HOME is unset/unwritable — which, being a predictable
    shared-`/tmp` path, is symlink-hardened: a link pre-planted at the stamp
    path is refused via a `[ -h ]` pre-check (before the `[ -O ]` owner check,
    which follows symlinks) so the throttle's `chmod`/write can never be
    redirected onto a victim-owned directory; the notice just prints every
    time instead. Suppress with `AXONFLOW_IDENTITY_NOTICE=off`;
  - exports `AXONFLOW_USER_IDENTITY_SOURCE` (`env` | `git` | `none`) alongside
    `AXONFLOW_USER_EMAIL_RESOLVED`.
  Source order is unchanged (env var → git → unset/header omitted).
  The **`.mcp.json` inline resolver** — the actual MCP-connection surface;
  `headersHelper` cannot reference plugin scripts — ports the same hardened
  resolution (sanitize-first fall-through, git probe + shim guard, merged →
  `--global` read) as POSIX sh. It deliberately omits the stderr notice:
  headersHelper stderr is not surfaced by Claude Code, so the hooks own the
  operator-visible diagnostic.
  Tests: `tests/test-user-identity.sh` grew the identity-ABSENT matrix
  (non-repo cwd, corrupt repo, dubious-ownership repo, deleted cwd,
  global-only, local-vs-global, blank env var, stripped-PATH probe, shim-guard
  wiring, diagnostic throttle/opt-out, tmp-stamp symlink refusal);
  `tests/test-mcp-headers.sh` pins the
  inline port (blank-env fall-through, corrupt-repo rescue);
  `tests/test-user-email-header-wire.sh` now asserts the REAL hooks fire the
  diagnostic when no identity is available and stay silent when one is.

## [1.8.0] - 2026-07-02 — per-developer + per-session identity (X-User-Email / X-Session-Id)

Pairs with platform **≥ 9.3.0**, which ingests `X-User-Email` and `X-Session-Id`
into the canonical audit row (migration `core/129` adds `audit_logs.session_id`).

### Added

- **Per-developer identity via `AXONFLOW_USER_EMAIL`.**
  The plugin now resolves a developer email — `AXONFLOW_USER_EMAIL` env var
  (the supported source), falling back best-effort to `git config user.email`,
  else unset — and sends it as the `X-User-Email` header on every governed
  request: the `.mcp.json` MCP connection, `pre-tool-check.sh` (`check_policy`)
  and `post-tool-audit.sh` (`check_output` / `audit_tool_call`). This attributes
  audit rows to a real person so the customer portal's **User** column and audit
  filter show the individual instead of the client-scoped synthetic
  `mcp-client:<org>` id. When no identity resolves the header is omitted
  entirely (the agent degrades to its synthetic id — never a blank column).
  New helper `scripts/user-identity.sh`; documented in the README under
  "Per-developer identity". Identity is *asserted*, not verified — it improves
  audit visibility, not authentication.
- **Per-session attribution via `X-Session-Id`.**
  The PreToolUse/PostToolUse hooks now forward Claude Code's `session_id` (from
  the hook stdin JSON) as the `X-Session-Id` header on the `check_policy` and
  `audit_tool_call` / `check_output` calls, so audit rows carry the AI-tool
  session alongside the developer email (platform migration core/129 adds
  `audit_logs.session_id`). No configuration needed — Claude Code always
  provides `session_id`. The `.mcp.json` MCP connection is unchanged (it has no
  per-call session id).
  - Tests: `tests/test-user-identity.sh` (resolution precedence + CR/LF
    sanitization), `tests/test-user-email-header-wire.sh` (both hooks emit
    `X-User-Email` when set / omit when unset, via a header-capturing mock
    agent), and new `X-User-Email` assertions in `tests/test-mcp-headers.sh`.

## [1.7.0] - 2026-06-30 — Hook denies and retries with redacted content on `requires_redaction` policies (no raw PII landing on disk)

Pairs with platform **≥ 9.2.2**, which adds `requires_redaction` and
`redacted_statement` to the `check_policy` (MCP check-input) response.

### Added

- **`runtime-e2e/2746_pii_redact_hook/`** — real-agent runtime test for the
  redaction-retry path ([axonflow-claude-plugin#98](https://github.com/getaxonflow/axonflow-claude-plugin/issues/98)).
  Against an agent configured with `PII_ACTION=redact`, it drives
  `pre-tool-check.sh` with a NIK-bearing `Write` and asserts the hook emits
  `permissionDecision: deny` with a non-empty `additionalContext` that carries
  the agent-masked statement (raw NIK absent); a clean `Write` is asserted to
  pass through with no deny. Skips gracefully when no `PII_ACTION=redact` agent
  is reachable.

### Fixed

- **PII under a redact-action policy is no longer written to disk in the
  clear ([axonflow-claude-plugin#98](https://github.com/getaxonflow/axonflow-claude-plugin/issues/98), plugin side of
  [axonflow-enterprise#2746](https://github.com/getaxonflow/axonflow-enterprise/issues/2746)).**
  When `check_policy` returns `requires_redaction: true`, `pre-tool-check.sh`
  now **denies** the tool call and returns the engine-masked
  `redacted_statement` to Claude in `additionalContext`, so Claude retries with
  clean content instead of letting the original `Write` execute with raw PII.
  For `Write`/`Edit` the `file_path` header is stripped so only the masked body
  is handed back (falling back to the full statement when the agent returns
  content with no path separator). The redaction event is recorded in the audit
  trail (fire-and-forget, statement omitted) so it appears alongside blocked
  events in compliance reports.
- **`Write`/`Edit` inputs are no longer truncated to 2000 characters before the
  policy check**, so PII past that offset can no longer slip past the redaction
  gate.
- **Wire-shape baseline registers `requires_redaction` and `redacted_statement`
  as known plugin-only fields on `MCPCheckInputResponse`**, keeping the
  wire-shape gate green in the window before the platform OpenAPI spec
  ([axonflow-enterprise#2747](https://github.com/getaxonflow/axonflow-enterprise/issues/2747)) is refreshed.

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
