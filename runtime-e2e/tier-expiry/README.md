# runtime-e2e/tier-expiry — V1 SaaS Plugin Pro tier-line expiry surface

## What it asserts

The user-facing `/axonflow-status` slash command (which invokes
`scripts/status.sh`) renders one of three tier-line shapes depending on
the configured Pro license token's JWT `exp` claim:

| State          | Shape                                                                         |
|----------------|-------------------------------------------------------------------------------|
| Free           | `tier=Free (no Pro license configured)`                                       |
| Pro active     | `tier=Pro (expires YYYY-MM-DD, N days remaining)`                             |
| Pro expired    | `tier=Free (Pro expired YYYY-MM-DD — visit https://getaxonflow.com/pro to renew)` |

Plus security guarantees:
- Full bearer token is NEVER printed; only the last 4 chars in the
  `AXON-...XXXX` redaction.
- Pro-expired output surfaces the renewal hint
  (`After renewal, run /axonflow-login --token <new>`).

## How to run

```bash
bash runtime-e2e/tier-expiry/test.sh
```

No env vars required. Mints three structurally-valid AXON- JWT tokens
on the fly (header.payload.signature, base64url-encoded per RFC 7519)
with explicit `exp` claims and runs the actual `scripts/status.sh`
against them in an isolated `$HOME` so the developer's real
`~/.config/axonflow` is never touched.

## Why this is real-surface runtime proof (HARD RULE #0)

- The script under test IS the script `/axonflow-status` invokes — same
  file, same path, same env-var resolution order.
- The license tokens are real AXON-prefixed JWTs (header.payload.sig
  base64url-encoded). The JWT-parsing branch in `status.sh` does NOT
  distinguish a platform-minted token from a test-minted one
  structurally — both decode the same way and exit the same code path.
  The platform's signature validation is a separate concern that lives
  in `PluginClaimMiddleware` on the agent and is exercised by
  `runtime-e2e/license-token/test.sh`.
- No network mock, no fake stdout capture, no shimmed command. We
  invoke the actual `scripts/status.sh` against an isolated `$HOME`
  and assert the actual stdout grep-shape.

## Coverage scope

- Free path (no token)              — Test 1
- Pro active (exp in future)        — Test 2 + token-leak guard + last-4 redaction
- Pro expired (exp in past)         — Test 3 + token-leak guard + renew CTA
- Wire-up (X-License-Token sent)    — `runtime-e2e/license-token/test.sh` (separate concern)
