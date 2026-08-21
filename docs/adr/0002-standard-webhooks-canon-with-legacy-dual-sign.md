# ADR-0002 — Standard Webhooks canon, with legacy dual-sign migration

- **Status:** Accepted (2026-08-20) — trued up 2026-08-21 when subscriptions landed (#6): the oracle is `AshHooks.Legacy.verify/5` (not `verify_legacy/5`); `signing_mode` is per-SUBSCRIPTION on the injected attribute (nullable, falling back to the resource outbound declaration mode, defaulting `:standard`); the outbound DSL opt is `subscriptions` + `deliveries` (resource modules)
- **Deciders:** operator (directive: "compatible if not canon"), scout + cross-family adversarial review

## Context

Outbound consumers must be able to verify deliveries with ordinary webhook libraries. The
Standard Webhooks spec defines `webhook-id` / `webhook-timestamp` / `webhook-signature`
(space-delimited `v1,<base64>`), MAC over `msg_id.timestamp.payload`, `whsec_`-prefixed
secrets, old+new rotation. The official Elixir reference lib (v0.1.1) is not on hex and is
non-interoperable (signs re-encoded maps, skips timestamp tolerance). A first-party adopter
currently emits a Stripe-shaped `t=<ts>,v1=<hex>` envelope with live receivers.

## Decision

Emit **Standard Webhooks canon** natively (no dependency — ~30 lines + ed25519, see
ADR-0006). During migration, a per-subscription `signing_mode` (`:legacy | :dual |
:standard`) additionally emits the legacy envelope **byte-identically**, signed with a
**separately imported incumbent secret** — independent keypairs, independent rotation
lifecycles. Cutover is operator-driven per subscription: a 2xx response cannot report which
header a receiver verified, so no auto-detection is attempted. An in-package
`verify_legacy/5` oracle proves byte-identity against the incumbent verifier.

## Consequences

- New consumers verify with any SW library; incumbent receivers keep verifying through cutover.
- Dual-sign doubles signature headers during migration; bounded by explicit mode flip.
- Native SW implementation owns spec-conformance testing (vectors cross-checked against
  reference implementations).
