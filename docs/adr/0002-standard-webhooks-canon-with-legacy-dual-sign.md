# ADR-0002 — Standard Webhooks canon, with legacy dual-sign migration

- **Status:** Accepted August 20, 2026; clarified August 21, 2026.
  `AshHooks.Legacy.verify/5` verifies the legacy envelope. A nullable subscription
  `signing_mode` falls back to the outbound declaration, then to `:standard`.
  The declaration names its `subscriptions` and `deliveries` resources.
- **Deciders:** maintainer (directive: "compatible if not canon"); independent design review

## Context

Outbound consumers must be able to verify deliveries with ordinary webhook libraries. The
Standard Webhooks spec defines `webhook-id` / `webhook-timestamp` / `webhook-signature`
(space-delimited `v1,<base64>`), MAC over `msg_id.timestamp.payload`, `whsec_`-prefixed
secrets, and key rotation. Existing receivers may also use the timestamped
`t=<ts>,v1=<hex>` envelope supported by `AshHooks.Legacy`.

## Decision

Emit **Standard Webhooks** natively (see
ADR-0006). During migration, a per-subscription `signing_mode` (`:legacy | :dual |
`:standard`) additionally emits the legacy envelope **byte-identically**, signed with a
**separate legacy secret** — independent keys and rotation
lifecycles. Cutover is operator-driven per subscription: a 2xx response cannot report which
header a receiver verified, so no auto-detection is attempted. An in-package
`AshHooks.Legacy.verify/5` verifier checks the legacy envelope.

## Consequences

- New consumers verify with any SW library; incumbent receivers keep verifying through cutover.
- Dual-sign doubles signature headers during migration; bounded by explicit mode flip.
- Native SW implementation owns spec-conformance testing (vectors cross-checked against
  reference implementations).
