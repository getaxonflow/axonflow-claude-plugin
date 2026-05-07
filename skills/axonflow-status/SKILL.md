---
name: axonflow-status
description: Show AxonFlow plugin status — tenant_id (needed for Stripe Pro upgrade), tier (Free/Pro), Pro license expiry date, endpoint, and config file paths
---

Use this skill when the user asks any of:

- "What is my AxonFlow tenant_id?" — needed to paste into the custom field at
  Stripe Checkout (`https://getaxonflow.com/pricing/`) when buying Pro.
- "Am I on Pro or Free tier?"
- "When does my Pro license expire?" / "How many days do I have left?"
- "Is my Pro license token loaded?"
- "Where does the plugin think AxonFlow is?" / "What endpoint am I hitting?"
- "How do I upgrade to Pro?" / "How do I renew?"

## What to do

1. **Prefer the MCP tool when available.** The AxonFlow agent exposes
   `axonflow_get_tenant_id` via the `axonflow` MCP server (auto-discovered
   when the `mcp__axonflow__*` toolset is allowed). If that tool is in the
   available toolset, call it first — it returns `tenant_id`, the
   caller's tier as resolved server-side from the credentials, and the
   canonical `upgrade_url` + `buy_url`. The MCP path is auth-context-aware
   and avoids spawning a shell.
2. **Fall back to the script** when the MCP tool isn't available (older
   agents, or the MCP server isn't wired in). Tell the user what you're
   about to do: "I'll run `scripts/status.sh` in your terminal to print
   your tenant_id, tier, and Pro license expiry." Then invoke the script
   via the Bash tool from the plugin install root:
   `$CLAUDE_PLUGIN_ROOT/scripts/status.sh`
   Equivalent to invoking the `/axonflow-status` slash command directly.
3. Surface the `tenant_id`, `tier`, and (when present) `expires` lines back
   to the user. If they asked about upgrading, point them at the
   `upgrade_url` returned by the tool / printed by the script, and remind
   them they need to paste the `tenant_id` into the Stripe Checkout
   custom field.

## Related agent-callable tools

When the AxonFlow MCP server is available the agent can answer related
questions directly via tool calls without spawning shell scripts:

- `axonflow_get_tenant_id` — tenant identity + tier + upgrade URLs.
- `axonflow_list_pro_features` — locked V1 Pro feature list (5
  differentiators + $9.99 / 90 days pricing). Useful when the user asks
  "what would I get if I upgraded?".
- `axonflow_request_approval` — file a HITL approval request before a
  risky operation (Free tier: 1 per rolling 7d; Pro: unlimited).
- `axonflow_create_tenant_policy` — create a custom tenant policy (Free
  tier: 2 active max; Pro: unlimited).
- `axonflow_get_cost_estimate` — pre-flight LLM cost for a multi-step
  plan. Pro-only — the tool isn't visible to Free callers.

Prefer these tools over equivalent shell scripts when both exist; they
are auth-context-aware on the server side and don't require local shell
state.

## Tier line shape

The script always emits a `tier=` line. The trailing parenthesis tells the
user where they stand:

- `tier=Pro (expires 2026-08-03, 90 days remaining)` — paid Pro tier active.
- `tier=Pro (expires 2026-08-03 — UNKNOWN remaining; could not parse token)`
  — token configured but exp claim could not be extracted (treat as Pro for
  display; the platform is the source of truth for validity).
- `tier=Free (Pro expired 2026-02-04 — visit https://getaxonflow.com/pricing/ to renew)`
  — token still configured but its `exp` is in the past. The plugin will
  not forward it on governed requests; user must renew.
- `tier=Free (no Pro license configured)` — no token has ever been loaded.

When `tier=Free (Pro expired ...)` shows up, recommend running
`/axonflow-login --token <new-token>` after renewal so the new token
overwrites the expired one in `~/.config/axonflow/license-token.json`.

## What this skill does NOT do

- It does NOT print the full Pro license token. Only the last 4 chars are
  shown (`AXON-...XXXX`) — the token is a bearer credential and the script
  output may be screen-shared or pasted into a support ticket. If the user
  asks for the full token, point them at the original Stripe / billing
  email rather than the script output.
- It does NOT call the agent to verify token validity — the platform is the
  source of truth. The script reports `Pro` whenever a non-expired token is
  loaded; if the agent later rejects the token (revoked, malformed, exp
  clock skew), the user will see that on their next governed tool call.
- It does NOT perform recovery. If `tenant_id` is missing and the user
  expected one, point them at `/axonflow-recover <email>`.

## When to suggest it

Suggest this skill when the user reports any of:

- "I'm trying to buy Pro and need my tenant_id"
- "How do I know if my Pro upgrade went through?"
- "When does my Pro license expire?"
- "Which AxonFlow am I connected to?"
- "Is my license token configured correctly?"

Do NOT suggest it for:

- Recovering lost credentials → use `/axonflow-recover` instead.
- Listing active overrides → use `/axonflow-list-overrides` instead.
- Searching audit logs → use `/audit-search` instead.
