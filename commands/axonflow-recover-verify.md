---
description: Consume an AxonFlow recovery magic-link token, mint fresh tenant credentials, and persist them to the plugin config
argument-hint: <recovery-token>
---

Consume a magic-link token issued by `/axonflow-recover` (or the auto-sent recovery email). On success the agent mints a fresh `tenant_id` + `secret` bound to the same email and the plugin persists them locally so subsequent governed calls authenticate as the recovered tenant.

Argument: $ARGUMENTS

Parse the argument as `<token>`. Tokens are 64-character hex strings. If missing or shorter than 32 characters, ask the user for the token they received in the magic-link email — they should copy the `token=…` value from the URL, not the URL itself.

Then run the plugin's `recover-verify.sh` helper using the `Bash` tool. The helper POSTs to `/api/v1/recover/verify` with `Content-Type: application/json` (programmatic flow — no HTML page in the loop), validates the response shape, and persists the new credentials atomically to `~/.config/axonflow/try-registration.json` (mode 0600 inside a 0700 directory — same file the Community-SaaS bootstrap reads on every hook invocation).

```
$CLAUDE_PLUGIN_ROOT/scripts/recover-verify.sh '<token>'
```

On success the script writes a single `OK tenant_id=… email=… endpoint=… expires_at=…` line followed by the platform's `note` and a reminder about the previous tenant's audit history. Surface those lines verbatim.

On failure (HTTP 401 = token invalid/expired/already consumed; 403 = per-email cap reached; 5xx = server error) the script exits non-zero with `ERR …` lines that include the platform's error message. Surface them verbatim and tell the user to start over with `/axonflow-recover <email>` if they still need to recover.
