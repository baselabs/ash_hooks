# ADR-0005 — Security floors ship in the package, not as consumer homework

- **Status:** Accepted (2026-08-20)
- **Deciders:** scout + cross-family adversarial review (Category-10 blocking finding)

## Context

Webhook payloads and ledgers carry untrusted input and secrets adjacent to authorization
boundaries. Delegating policies/classification entirely to "consumer-side concerns" strips
the safety floors the reference platform runs (scoped reads, field policies, encrypted
secrets) from the reusable package — an authorization and data-exposure regression for
adopters with no migration layer, and a banned restriction-shaped narrowing.

## Decision

The package ships RESTRICTIVE DEFAULTS as floors, which consumers relax explicitly:
default-deny reads on ledger/delivery resources; stored inbound headers allowlisted
(signature headers by default); outbound response bodies stored as bounded redacted
snippets; secrets resolvable only via callbacks (stored as digest + redacted display;
literal secrets in DSL/config rejected at compile time); telemetry carries 8-hex secret
fingerprints only; retention (TTL) and field-redaction hooks provided; SSRF guard enforced
at endpoint registration AND send time (scheme, private/link-local/metadata ranges,
send-time DNS re-resolution); per-endpoint circuit breaking is a durable `:disabled`
transition on the Endpoint resource (plus the 410 rule), not an in-process fuse. Inbound
pipeline is verify-before-trust, fail-closed on missing secrets / missing raw body
(loud misconfiguration error, never silent accept).

## Consequences

- Adopters restore parity through declared slots + hooks rather than reimplementing floors.
- Raw payloads persist by default (verification and audit require them) — bounded by
  retention hooks and redaction on read surfaces.
- Slightly more concept surface than a bare engine; each floor maps to a named silent
  failure mode.
